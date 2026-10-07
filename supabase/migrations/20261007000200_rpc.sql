-- Write and pull API. Clients never write tables directly.
--
-- Conventions
--   * Every function requires an authenticated caller (SQLSTATE 28000 otherwise).
--   * Writes are idempotent: replaying the same payload returns the current row without changing it, so
--     a retried outbox operation never duplicates data or bumps versions.
--   * SQLSTATE meanings: 28000 not authenticated, 42501 not allowed, 22023 invalid parameter,
--     P0002 referenced row not found, 23505 id already used with different data,
--     40001 version conflict (the row changed since `p_base_version`).

create function public.caller_user_id() returns uuid
language sql stable security definer set search_path = public as $$
    select id from public.users where auth_user_id = auth.uid();
$$;

-- Links the device's local user to the authenticated account (called after registration or login).
create function public.claim_user(p_id uuid, p_name text, p_email text, p_created_at timestamptz)
returns public.users
language plpgsql security definer set search_path = public as $$
declare
    v_uid uuid := auth.uid();
    v_name text := btrim(p_name);
    v_email text := nullif(btrim(p_email), '');
    v_row public.users;
begin
    if v_uid is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    if v_name is null or v_name = '' then raise exception 'name is required' using errcode = '22023'; end if;
    if exists (select 1 from public.users where auth_user_id = v_uid and id <> p_id) then
        raise exception 'account is already linked to another user' using errcode = '42501';
    end if;

    select * into v_row from public.users where id = p_id for update;
    if not found then
        insert into public.users (id, name, email, owner_auth_id, auth_user_id, created_at)
        values (p_id, v_name, v_email, v_uid, v_uid, p_created_at)
        returning * into v_row;
    elsif v_row.auth_user_id = v_uid then
        if v_row.name is distinct from v_name or v_row.email is distinct from v_email then
            update public.users set name = v_name, email = v_email where id = p_id returning * into v_row;
        end if;
    elsif v_row.auth_user_id is null and v_row.owner_auth_id = v_uid then
        update public.users set name = v_name, email = v_email, auth_user_id = v_uid
        where id = p_id returning * into v_row;
    else
        raise exception 'user belongs to another account' using errcode = '42501';
    end if;
    return v_row;
end;
$$;

-- Creates a participant without an account, owned by the caller.
create function public.upsert_participant(p_id uuid, p_name text, p_email text, p_created_at timestamptz)
returns public.users
language plpgsql security definer set search_path = public as $$
declare
    v_uid uuid := auth.uid();
    v_name text := btrim(p_name);
    v_email text := nullif(btrim(p_email), '');
    v_row public.users;
begin
    if v_uid is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    if public.caller_user_id() is null then
        raise exception 'claim your user before adding participants' using errcode = '42501';
    end if;
    if v_name is null or v_name = '' then raise exception 'name is required' using errcode = '22023'; end if;

    select * into v_row from public.users where id = p_id for update;
    if not found then
        insert into public.users (id, name, email, owner_auth_id, created_at)
        values (p_id, v_name, v_email, v_uid, p_created_at)
        returning * into v_row;
    elsif v_row.owner_auth_id <> v_uid then
        raise exception 'user belongs to another account' using errcode = '42501';
    elsif v_row.name is distinct from v_name or v_row.email is distinct from v_email then
        update public.users set name = v_name, email = v_email where id = p_id returning * into v_row;
    end if;
    return v_row;
end;
$$;

create function public.create_group(
    p_id uuid, p_name text, p_currency text, p_created_by uuid, p_created_at timestamptz
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
    v_name text := btrim(p_name);
    v_row public.groups;
begin
    if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    if p_created_by is distinct from public.caller_user_id() then
        raise exception 'groups can only be created by the caller' using errcode = '42501';
    end if;
    if v_name is null or v_name = '' then raise exception 'name is required' using errcode = '22023'; end if;
    if p_currency not in ('EUR', 'USD', 'GBP', 'JPY') then
        raise exception 'unsupported currency %', p_currency using errcode = '22023';
    end if;

    select * into v_row from public.groups where id = p_id for update;
    if not found then
        insert into public.groups (id, name, currency, created_by, created_at)
        values (p_id, v_name, p_currency, p_created_by, p_created_at)
        returning * into v_row;
    elsif v_row.name <> v_name or v_row.currency <> p_currency or v_row.created_by <> p_created_by then
        raise exception 'group id already exists with different data' using errcode = '23505';
    end if;
    return v_row;
end;
$$;

-- Adds a member to a group. The caller must be a member, or the creator adding the first member.
-- The added user must be the caller's own user or a participant the caller created.
create function public.add_member(p_id uuid, p_group_id uuid, p_user_id uuid, p_created_at timestamptz)
returns public.group_members
language plpgsql security definer set search_path = public as $$
declare
    v_uid uuid := auth.uid();
    v_group public.groups;
    v_row public.group_members;
begin
    if v_uid is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    select * into v_group from public.groups where id = p_group_id;
    if not found then raise exception 'group not found' using errcode = 'P0002'; end if;
    if not (public.is_group_member(p_group_id) or v_group.created_by = public.caller_user_id()) then
        raise exception 'not allowed to add members to this group' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.users where id = p_user_id and (owner_auth_id = v_uid or auth_user_id = v_uid)
    ) then
        raise exception 'user not found or not owned by the caller' using errcode = '42501';
    end if;

    select * into v_row from public.group_members where group_id = p_group_id and user_id = p_user_id;
    if found then
        if v_row.id <> p_id then
            raise exception 'user is already a member with a different membership id' using errcode = '23505';
        end if;
        return v_row;
    end if;
    if exists (select 1 from public.group_members where id = p_id) then
        raise exception 'membership id already used' using errcode = '23505';
    end if;

    insert into public.group_members (id, group_id, user_id, created_at)
    values (p_id, p_group_id, p_user_id, p_created_at)
    returning * into v_row;
    return v_row;
end;
$$;

-- Joins the caller's own user to a group using its invite code.
create function public.join_group(p_id uuid, p_group_id uuid, p_invite_code uuid, p_created_at timestamptz)
returns public.group_members
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := public.caller_user_id();
    v_row public.group_members;
begin
    if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    if v_user is null then raise exception 'claim your user before joining a group' using errcode = '42501'; end if;
    if not exists (select 1 from public.groups where id = p_group_id and invite_code = p_invite_code) then
        raise exception 'invalid group or invite code' using errcode = '42501';
    end if;

    select * into v_row from public.group_members where group_id = p_group_id and user_id = v_user;
    if found then return v_row; end if;
    if exists (select 1 from public.group_members where id = p_id) then
        raise exception 'membership id already used' using errcode = '23505';
    end if;
    insert into public.group_members (id, group_id, user_id, created_at)
    values (p_id, p_group_id, v_user, p_created_at)
    returning * into v_row;
    return v_row;
end;
$$;

-- Creates or updates an expense together with all of its splits, atomically.
--   p_splits:       [{"id": uuid, "user_id": uuid, "amount_minor": bigint}, ...]
--   p_base_version: 0 when creating, otherwise the version the client last saw.
-- The currency is always the group's. Deleting is `p_deleted_at` (soft delete).
create function public.upsert_expense(
    p_id uuid, p_group_id uuid, p_paid_by uuid, p_title text, p_amount_minor bigint,
    p_created_at timestamptz, p_updated_at timestamptz, p_deleted_at timestamptz,
    p_splits jsonb, p_base_version bigint
) returns public.expenses
language plpgsql security definer set search_path = public as $$
declare
    v_group public.groups;
    v_title text := btrim(p_title);
    v_row public.expenses;
    v_count int;
    v_sum bigint;
    v_same_splits boolean;
    v_splits jsonb;
begin
    if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
    select * into v_group from public.groups where id = p_group_id;
    if not found then raise exception 'group not found' using errcode = 'P0002'; end if;
    if not public.is_group_member(p_group_id) then
        raise exception 'not a member of this group' using errcode = '42501';
    end if;
    if v_title is null or v_title = '' then raise exception 'title is required' using errcode = '22023'; end if;
    if p_amount_minor is null or p_amount_minor <= 0 then
        raise exception 'amount must be greater than zero' using errcode = '22023';
    end if;
    if not exists (select 1 from public.group_members where group_id = p_group_id and user_id = p_paid_by) then
        raise exception 'payer is not a member of the group' using errcode = '22023';
    end if;

    v_splits := coalesce(p_splits, '[]'::jsonb);
    if jsonb_typeof(v_splits) <> 'array' then raise exception 'splits must be an array' using errcode = '22023'; end if;

    select count(*), coalesce(sum(amount_minor), 0) into v_count, v_sum
    from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint);
    if v_count = 0 then raise exception 'at least one split is required' using errcode = '22023'; end if;
    if exists (
        select 1 from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint)
        where s.id is null or s.user_id is null or s.amount_minor is null or s.amount_minor < 0
    ) then
        raise exception 'invalid split' using errcode = '22023';
    end if;
    if (select count(distinct s.user_id) from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint)) <> v_count then
        raise exception 'duplicate participant in splits' using errcode = '22023';
    end if;
    if exists (
        select 1 from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint)
        where not exists (select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = s.user_id)
    ) then
        raise exception 'a split user is not a member of the group' using errcode = '22023';
    end if;
    if v_sum <> p_amount_minor then
        raise exception 'splits add up to % but the amount is %', v_sum, p_amount_minor using errcode = '22023';
    end if;

    select * into v_row from public.expenses where id = p_id for update;
    if not found then
        if p_base_version <> 0 then
            raise exception 'expense not found' using errcode = 'P0002';
        end if;
        insert into public.expenses (id, group_id, paid_by, title, amount_minor, currency, created_at, updated_at, deleted_at)
        values (p_id, p_group_id, p_paid_by, v_title, p_amount_minor, v_group.currency, p_created_at, p_updated_at, p_deleted_at)
        returning * into v_row;
    else
        if v_row.group_id <> p_group_id then
            raise exception 'expense belongs to another group' using errcode = '22023';
        end if;
        select not exists (
            (select user_id, amount_minor from public.expense_splits where expense_id = p_id
             except select s.user_id, s.amount_minor
                    from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint))
            union all
            (select s.user_id, s.amount_minor
             from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint)
             except select user_id, amount_minor from public.expense_splits where expense_id = p_id)
        ) into v_same_splits;

        if v_row.paid_by = p_paid_by and v_row.title = v_title and v_row.amount_minor = p_amount_minor
           and v_row.deleted_at is not distinct from p_deleted_at and v_same_splits then
            return v_row; -- replay of an operation that already took effect
        end if;
        if p_base_version <> v_row.version then
            raise exception 'version conflict: current version is %', v_row.version
                using errcode = '40001', detail = 'current_version=' || v_row.version;
        end if;

        update public.expenses
        set paid_by = p_paid_by, title = v_title, amount_minor = p_amount_minor,
            updated_at = p_updated_at, deleted_at = p_deleted_at
        where id = p_id
        returning * into v_row;
        delete from public.expense_splits where expense_id = p_id;
    end if;

    insert into public.expense_splits (id, expense_id, user_id, amount_minor)
    select s.id, p_id, s.user_id, s.amount_minor
    from jsonb_to_recordset(v_splits) as s(id uuid, user_id uuid, amount_minor bigint);
    return v_row;
end;
$$;

-- Changes visible to the caller with `server_seq > p_since`, oldest first. Runs with the caller's
-- privileges, so row level security decides what is returned. Pass `p_group_id` to fetch the complete
-- history of one group (used after the caller joins a group, whose old rows are below their cursor).
create function public.pull_changes(p_since bigint default 0, p_limit int default 500, p_group_id uuid default null)
returns table (entity text, server_seq bigint, payload jsonb)
language sql stable security invoker set search_path = public as $$
    select c.entity, c.seq, c.payload
    from (
        select 'user'::text as entity, u.server_seq as seq, to_jsonb(u) - 'owner_auth_id' as payload
        from public.users u
        where u.server_seq > p_since
          and (p_group_id is null or exists (
              select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = u.id))
        union all
        select 'group', g.server_seq, to_jsonb(g)
        from public.groups g
        where g.server_seq > p_since and (p_group_id is null or g.id = p_group_id)
        union all
        select 'group_member', gm.server_seq, to_jsonb(gm)
        from public.group_members gm
        where gm.server_seq > p_since and (p_group_id is null or gm.group_id = p_group_id)
        union all
        select 'expense', e.server_seq,
               to_jsonb(e) || jsonb_build_object('splits', coalesce((
                   select jsonb_agg(jsonb_build_object('id', s.id, 'user_id', s.user_id, 'amount_minor', s.amount_minor)
                                    order by s.user_id)
                   from public.expense_splits s where s.expense_id = e.id), '[]'::jsonb))
        from public.expenses e
        where e.server_seq > p_since and (p_group_id is null or e.group_id = p_group_id)
    ) c
    order by c.seq, c.entity
    limit p_limit;
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

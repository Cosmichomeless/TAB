-- TAB remote model. Mirrors docs/architecture/data-model.md.
--
-- Access model:
--   * Every table has row level security enabled and clients may only SELECT, and only rows of groups
--     they belong to.
--   * All writes go through the SECURITY DEFINER functions in 20261007000200_rpc.sql, which validate
--     invariants (membership, currency, splits adding up to the amount) and are idempotent.

create sequence public.change_seq;

-- Sets the server-assigned sync columns on every insert and update.
create function public.bump_version() returns trigger
language plpgsql as $$
begin
    new.server_seq := nextval('public.change_seq');
    if tg_op = 'INSERT' then
        new.version := 1;
    else
        new.version := old.version + 1;
    end if;
    return new;
end;
$$;

-- Users: registered people and participants without an account (auth_user_id is null).
create table public.users (
    id uuid primary key,
    name text not null check (length(btrim(name)) > 0),
    email text,
    -- Account that created the row; owns placeholder participants.
    owner_auth_id uuid not null references auth.users (id),
    -- Set once the person registers and claims the row.
    auth_user_id uuid unique references auth.users (id),
    created_at timestamptz not null,
    version bigint not null default 0,
    server_seq bigint not null default 0
);

create table public.groups (
    id uuid primary key,
    name text not null check (length(btrim(name)) > 0),
    currency text not null check (currency in ('EUR', 'USD', 'GBP', 'JPY')),
    created_by uuid not null references public.users (id),
    -- Secret shared with people who should be able to join; only members can read it.
    invite_code uuid not null default gen_random_uuid(),
    created_at timestamptz not null,
    version bigint not null default 0,
    server_seq bigint not null default 0
);

create table public.group_members (
    id uuid primary key,
    group_id uuid not null references public.groups (id),
    user_id uuid not null references public.users (id),
    created_at timestamptz not null,
    version bigint not null default 0,
    server_seq bigint not null default 0,
    unique (group_id, user_id)
);

create index group_members_user on public.group_members (user_id);

create table public.expenses (
    id uuid primary key,
    group_id uuid not null references public.groups (id),
    paid_by uuid not null references public.users (id),
    title text not null check (length(btrim(title)) > 0),
    amount_minor bigint not null check (amount_minor > 0),
    currency text not null check (currency in ('EUR', 'USD', 'GBP', 'JPY')),
    created_at timestamptz not null,
    updated_at timestamptz not null,
    deleted_at timestamptz,
    version bigint not null default 0,
    server_seq bigint not null default 0
);

create index expenses_group on public.expenses (group_id, server_seq);

-- Splits belong to their expense: they are replaced together with it and have no sync columns of
-- their own. Every change to them bumps the expense version.
create table public.expense_splits (
    id uuid primary key,
    expense_id uuid not null references public.expenses (id),
    user_id uuid not null references public.users (id),
    amount_minor bigint not null check (amount_minor >= 0),
    unique (expense_id, user_id)
);

create index users_server_seq on public.users (server_seq);
create index groups_server_seq on public.groups (server_seq);
create index group_members_server_seq on public.group_members (server_seq);
create index expenses_server_seq on public.expenses (server_seq);

create trigger users_bump before insert or update on public.users
    for each row execute function public.bump_version();
create trigger groups_bump before insert or update on public.groups
    for each row execute function public.bump_version();
create trigger group_members_bump before insert or update on public.group_members
    for each row execute function public.bump_version();
create trigger expenses_bump before insert or update on public.expenses
    for each row execute function public.bump_version();

-- Membership helpers. SECURITY DEFINER so policies do not recurse through RLS.
create function public.is_group_member(p_group_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from public.group_members gm
        join public.users u on u.id = gm.user_id
        where gm.group_id = p_group_id and u.auth_user_id = auth.uid()
    );
$$;

create function public.shares_group_with(p_user_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from public.group_members theirs
        join public.group_members mine on mine.group_id = theirs.group_id
        join public.users me on me.id = mine.user_id
        where theirs.user_id = p_user_id and me.auth_user_id = auth.uid()
    );
$$;

alter table public.users enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_splits enable row level security;

create policy users_select on public.users for select to authenticated
    using (owner_auth_id = auth.uid() or auth_user_id = auth.uid() or public.shares_group_with (id));

create policy groups_select on public.groups for select to authenticated
    using (public.is_group_member (id));

create policy group_members_select on public.group_members for select to authenticated
    using (public.is_group_member (group_id));

create policy expenses_select on public.expenses for select to authenticated
    using (public.is_group_member (group_id));

-- The subquery is itself filtered by the expenses policy.
create policy expense_splits_select on public.expense_splits for select to authenticated
    using (exists (select 1 from public.expenses e where e.id = expense_id));

-- No INSERT/UPDATE/DELETE policies exist: direct writes are denied. Make that explicit even if
-- default privileges grant more.
revoke all on public.users, public.groups, public.group_members, public.expenses, public.expense_splits
    from anon, authenticated;
grant select on public.users, public.groups, public.group_members, public.expenses, public.expense_splits
    to authenticated;

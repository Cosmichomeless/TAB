-- Assertions for row level security and the write/pull RPCs. Each DO block acts as one or more users by
-- setting the JWT subject and switching to the `authenticated` role, exactly like PostgREST does.

insert into auth.users (id, email) values
    ('a0000000-0000-0000-0000-000000000001', 'david@example.com'),
    ('a0000000-0000-0000-0000-000000000002', 'ana@example.com'),
    ('a0000000-0000-0000-0000-000000000003', 'eve@example.com');

create schema t;
grant usage on schema t to authenticated, anon;
create function t.become(p_auth uuid) returns void language plpgsql as $$
begin
    perform set_config('request.jwt.claim.sub', coalesce(p_auth::text, ''), false);
end;
$$;
grant execute on function t.become(uuid) to authenticated, anon;

-- Setup: David and Ana each claim a user; David creates a group with Ana, a placeholder (Marta) and an expense.
do $$
declare
    david constant uuid := 'a0000000-0000-0000-0000-000000000001';
    ana   constant uuid := 'a0000000-0000-0000-0000-000000000002';
    u_david constant uuid := 'd0000000-0000-0000-0000-000000000001';
    u_ana   constant uuid := 'd0000000-0000-0000-0000-000000000002';
    u_marta constant uuid := 'd0000000-0000-0000-0000-000000000003';
    g constant uuid := 'c0000000-0000-0000-0000-000000000001';
    r record;
begin
    set role authenticated;
    perform t.become(david);
    perform public.claim_user(u_david, 'David', 'david@example.com', now());
    perform public.create_group(g, 'Lisbon', 'EUR', u_david, now());
    perform public.add_member('e0000000-0000-0000-0000-000000000001', g, u_david, now());
    perform public.upsert_participant(u_marta, 'Marta', null, now());
    perform public.add_member('e0000000-0000-0000-0000-000000000003', g, u_marta, now());

    perform t.become(ana);
    perform public.claim_user(u_ana, 'Ana', 'ana@example.com', now());
    reset role;
end $$;

-- Ana is not a member yet: she sees nothing of the group.
do $$
declare n int;
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000002');
    select count(*) into n from public.groups;
    assert n = 0, 'non-member must not see groups';
    select count(*) into n from public.pull_changes(0, 100, null) where entity in ('group', 'group_member', 'expense');
    assert n = 0, 'non-member must not pull group data';
    begin
        perform public.upsert_expense('f0000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000001', 'Sneaky', 100, now(), now(), null,
            '[{"id":"b0000000-0000-0000-0000-0000000000a1","user_id":"d0000000-0000-0000-0000-000000000001","amount_minor":100}]', 0);
        assert false, 'non-member must not write expenses';
    exception when sqlstate '42501' then null;
    end;
    begin
        perform public.add_member('e0000000-0000-0000-0000-0000000000a2', 'c0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000002', now());
        assert false, 'non-member must not add themselves';
    exception when sqlstate '42501' then null;
    end;
    reset role;
end $$;

-- Direct writes are impossible for clients.
do $$
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000001');
    begin
        insert into public.expenses (id, group_id, paid_by, title, amount_minor, currency, created_at, updated_at)
        values (gen_random_uuid(), 'c0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'x', 1, 'EUR', now(), now());
        assert false, 'direct insert must be denied';
    exception when insufficient_privilege then null;
    end;
    begin
        update public.groups set name = 'hacked';
        assert false, 'direct update must be denied';
    exception when insufficient_privilege then null;
    end;
    reset role;
end $$;

-- Members cannot add users owned by somebody else, and the invite code is the way in.
do $$
declare
    code uuid;
    r record;
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000001');
    begin
        perform public.add_member('e0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000002', now());
        assert false, 'a member cannot add a user owned by someone else';
    exception when sqlstate '42501' then null;
    end;
    select invite_code into code from public.groups where id = 'c0000000-0000-0000-0000-000000000001';
    assert code is not null, 'members can read the invite code';

    perform t.become('a0000000-0000-0000-0000-000000000002');
    begin
        perform public.join_group('e0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', gen_random_uuid(), now());
        assert false, 'wrong invite code must be rejected';
    exception when sqlstate '42501' then null;
    end;
    perform public.join_group('e0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', code, now());
    -- idempotent replay
    select * into r from public.join_group('e0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', code, now());
    assert r.id = 'e0000000-0000-0000-0000-000000000002', 'join replay returns the same membership';
    assert (select count(*) from public.group_members where group_id = 'c0000000-0000-0000-0000-000000000001') = 3;
    reset role;
end $$;

-- Eve (registered, no group) cannot see or learn anything about the group.
do $$
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000003');
    assert (select count(*) from public.groups) = 0;
    assert (select count(*) from public.users) = 0, 'users are visible only through shared groups';
    assert (select count(*) from public.expense_splits) = 0;
    reset role;
end $$;

-- Expense lifecycle: create, replay, validations, update with versions, conflict, soft delete.
do $$
declare
    g constant uuid := 'c0000000-0000-0000-0000-000000000001';
    u_david constant uuid := 'd0000000-0000-0000-0000-000000000001';
    u_ana   constant uuid := 'd0000000-0000-0000-0000-000000000002';
    u_marta constant uuid := 'd0000000-0000-0000-0000-000000000003';
    x constant uuid := 'f0000000-0000-0000-0000-000000000001';
    splits3 constant jsonb := jsonb_build_array(
        jsonb_build_object('id', 'b0000000-0000-0000-0000-000000000001', 'user_id', u_david, 'amount_minor', 334),
        jsonb_build_object('id', 'b0000000-0000-0000-0000-000000000002', 'user_id', u_ana, 'amount_minor', 333),
        jsonb_build_object('id', 'b0000000-0000-0000-0000-000000000003', 'user_id', u_marta, 'amount_minor', 333));
    r public.expenses;
    v1 bigint;
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000002'); -- Ana, now a member

    r := public.upsert_expense(x, g, u_ana, 'Dinner', 1000, now(), now(), null, splits3, 0);
    assert r.version = 1 and r.currency = 'EUR', 'created at version 1 with the group currency';
    v1 := r.server_seq;

    r := public.upsert_expense(x, g, u_ana, 'Dinner', 1000, now(), now(), null, splits3, 0);
    assert r.version = 1 and r.server_seq = v1, 'replay of the creation changes nothing';
    assert (select count(*) from public.expenses) = 1 and (select count(*) from public.expense_splits) = 3;

    begin
        perform public.upsert_expense(gen_random_uuid(), g, u_ana, 'Bad sum', 1000, now(), now(), null,
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'user_id', u_ana, 'amount_minor', 999)), 0);
        assert false, 'splits must add up to the amount';
    exception when sqlstate '22023' then null;
    end;
    begin
        perform public.upsert_expense(gen_random_uuid(), g, u_ana, 'Outsider', 100, now(), now(), null,
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'user_id', gen_random_uuid(), 'amount_minor', 100)), 0);
        assert false, 'split users must be members';
    exception when sqlstate '22023' then null;
    end;
    begin
        perform public.upsert_expense(gen_random_uuid(), g, u_ana, 'Dup', 100, now(), now(), null,
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'user_id', u_ana, 'amount_minor', 50),
                              jsonb_build_object('id', gen_random_uuid(), 'user_id', u_ana, 'amount_minor', 50)), 0);
        assert false, 'a participant can appear only once';
    exception when sqlstate '22023' then null;
    end;
    begin
        perform public.upsert_expense(gen_random_uuid(), g, u_ana, 'Zero', 0, now(), now(), null, splits3, 0);
        assert false, 'amount must be positive';
    exception when sqlstate '22023' then null;
    end;

    -- David (up to date at version 1) edits; Ana's stale edit then conflicts.
    perform t.become('a0000000-0000-0000-0000-000000000001');
    r := public.upsert_expense(x, g, u_ana, 'Dinner out', 1000, now(), now(), null, splits3, 1);
    assert r.version = 2 and r.title = 'Dinner out' and r.server_seq > v1, 'update bumps version and server_seq';

    perform t.become('a0000000-0000-0000-0000-000000000002');
    begin
        perform public.upsert_expense(x, g, u_ana, 'Dinner at Ana''s', 1000, now(), now(), null, splits3, 1);
        assert false, 'stale base version must conflict';
    exception when sqlstate '40001' then null;
    end;
    -- the already-applied edit replays idempotently even with the old base version
    perform t.become('a0000000-0000-0000-0000-000000000001');
    r := public.upsert_expense(x, g, u_ana, 'Dinner out', 1000, now(), now(), null, splits3, 1);
    assert r.version = 2, 'replay of an applied edit does not bump the version';

    -- changing the splits replaces them and bumps the version
    r := public.upsert_expense(x, g, u_ana, 'Dinner out', 1000, now(), now(), null,
        jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'user_id', u_david, 'amount_minor', 500),
                          jsonb_build_object('id', gen_random_uuid(), 'user_id', u_ana, 'amount_minor', 500)), 2);
    assert r.version = 3 and (select count(*) from public.expense_splits where expense_id = x) = 2;

    -- soft delete
    r := public.upsert_expense(x, g, u_ana, 'Dinner out', 1000, now(), now(), now(),
        jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'user_id', u_david, 'amount_minor', 500),
                          jsonb_build_object('id', gen_random_uuid(), 'user_id', u_ana, 'amount_minor', 500)), 3);
    assert r.version = 4 and r.deleted_at is not null;
    reset role;
end $$;

-- Pull: incremental cursor, per-group snapshot, ordering and payload shape.
do $$
declare
    g constant uuid := 'c0000000-0000-0000-0000-000000000001';
    n int;
    last_seq bigint;
    payload jsonb;
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000002');

    select count(*), max(server_seq) into n, last_seq from public.pull_changes(0, 1000, null);
    assert n >= 6, 'full pull returns users, group, members and the expense';
    assert (select bool_and(s.server_seq >= prev) from (
        select server_seq, coalesce(lag(server_seq) over (order by server_seq), 0) as prev from public.pull_changes(0, 1000, null)) s),
        'results are ordered by server_seq';
    assert (select count(*) from public.pull_changes(last_seq, 1000, null)) = 0, 'nothing newer than the cursor';
    assert (select count(*) from public.pull_changes(0, 2, null)) = 2, 'limit is honoured';

    select p.payload into payload from public.pull_changes(0, 1000, g) p where p.entity = 'expense';
    assert jsonb_array_length(payload -> 'splits') = 2, 'expense payload embeds its splits';
    assert payload ->> 'version' = '4', 'expense payload carries the version';
    assert not exists (select 1 from public.pull_changes(0, 1000, g) p where p.payload ? 'owner_auth_id'), 'owner_auth_id never leaves the server';

    -- a snapshot with an old cursor still works after joining late: since=0 and group filter return the group history
    assert (select count(*) from public.pull_changes(0, 1000, g) where entity = 'group_member') = 3;
    reset role;
end $$;

-- Anonymous callers can do nothing.
do $$
begin
    set role anon;
    begin
        perform public.pull_changes(0, 10, null);
        assert false, 'anon must not call pull_changes';
    exception when insufficient_privilege then null;
    end;
    reset role;
end $$;

-- Claiming: an account links to exactly one user, and cannot take someone else's.
do $$
begin
    set role authenticated;
    perform t.become('a0000000-0000-0000-0000-000000000003');
    begin
        perform public.claim_user('d0000000-0000-0000-0000-000000000001', 'Eve', null, now());
        assert false, 'cannot claim a user that belongs to another account';
    exception when sqlstate '42501' then null;
    end;
    perform public.claim_user('d0000000-0000-0000-0000-0000000000e1', 'Eve', null, now());
    begin
        perform public.claim_user('d0000000-0000-0000-0000-0000000000e2', 'Eve 2', null, now());
        assert false, 'an account links to one user only';
    exception when sqlstate '42501' then null;
    end;
    reset role;
end $$;

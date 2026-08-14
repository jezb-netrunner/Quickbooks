-- Phase 7: bank import dedupes and posts through the engine, rules drive the
-- queue, the review workflow gates posting, attachments are tenant-walled in
-- storage, the audit log covers the books, and the practice dashboard shows
-- each firm only its own clients.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(25);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_ar',    id from public.accounts where client_id = tap.v('a1') and code = '1100';
grant insert on tap.ctx to authenticated;

-- ------------------------------------------------------------ bank import
select tap.login('22222222-2222-4222-8222-222222222202');
select is(
  (select inserted from public.import_bank_txns(tap.v('a1'), tap.v('acc_cash'), '[
     {"d": "2026-08-01", "m": "GCASH TRANSFER IN", "a": 500},
     {"d": "2026-08-02", "m": "RENT AUG", "a": -200},
     {"d": "2026-08-03", "m": "BANK FEE", "a": -15}
   ]'::jsonb)),
  3, 'three bank lines import'
);
select ok(
  (select inserted = 0 and duplicates = 3 from public.import_bank_txns(tap.v('a1'), tap.v('acc_cash'), '[
     {"d": "2026-08-01", "m": "GCASH TRANSFER IN", "a": 500},
     {"d": "2026-08-02", "m": "RENT AUG", "a": -200},
     {"d": "2026-08-03", "m": "BANK FEE", "a": -15}
   ]'::jsonb)),
  're-importing the same file inserts nothing — fingerprints catch all three'
);
insert into tap.ctx select 'bt_in',  id from public.bank_txns where client_id = tap.v('a1') and description = 'GCASH TRANSFER IN';
insert into tap.ctx select 'bt_out', id from public.bank_txns where client_id = tap.v('a1') and description = 'RENT AUG';
insert into tap.ctx select 'bt_fee', id from public.bank_txns where client_id = tap.v('a1') and description = 'BANK FEE';

select public.categorize_bank_txn(tap.v('bt_in'), tap.v('acc_sales'));
select ok(
  (select b.status = 'categorized'
      and (select sum(l.debit) from public.journal_lines l
           where l.entry_id = b.entry_id and l.account_id = tap.v('acc_cash')) = 500.00
      and (select sum(l.credit) from public.journal_lines l
           where l.entry_id = b.entry_id and l.account_id = tap.v('acc_sales')) = 500.00
   from public.bank_txns b where b.id = tap.v('bt_in')),
  'an inflow posts DR bank / CR the chosen account'
);
select public.categorize_bank_txn(tap.v('bt_out'), tap.v('acc_rent'));
select ok(
  (select (select sum(l.debit) from public.journal_lines l
           where l.entry_id = b.entry_id and l.account_id = tap.v('acc_rent')) = 200.00
      and (select sum(l.credit) from public.journal_lines l
           where l.entry_id = b.entry_id and l.account_id = tap.v('acc_cash')) = 200.00
   from public.bank_txns b where b.id = tap.v('bt_out')),
  'an outflow posts DR the chosen account / CR bank'
);
select throws_like(
  $$ select public.categorize_bank_txn(tap.v('bt_fee'), tap.v('acc_ar')) $$,
  '%control accounts are posted by their own flows%',
  'bank lines cannot post straight into a control account'
);
select throws_like(
  $$ select public.categorize_bank_txn(tap.v('bt_in'), tap.v('acc_rent')) $$,
  '%only pending%',
  'a categorized line cannot be categorized twice'
);

-- rules
select public.import_bank_txns(tap.v('a1'), tap.v('acc_cash'), '[
  {"d": "2026-08-05", "m": "MERALCO ELECTRIC BILL", "a": -100},
  {"d": "2026-08-06", "m": "MYSTERY CHARGE", "a": -50}
]'::jsonb);
insert into public.bank_rules (client_id, match_text, account_id)
values (tap.v('a1'), 'meralco', tap.v('acc_rent'));
select is(
  (select public.apply_bank_rules(tap.v('a1'))),
  1, 'rules categorize the matching pending line and leave the rest'
);
insert into tap.ctx select 'bt_myst', id from public.bank_txns where client_id = tap.v('a1') and description = 'MYSTERY CHARGE';
select public.exclude_bank_txn(tap.v('bt_myst'), 'personal');
select public.restore_bank_txn(tap.v('bt_myst'));
select ok(
  (select count(*) filter (where description = 'BANK FEE' and status = 'pending') = 1
      and count(*) filter (where description = 'MYSTERY CHARGE' and status = 'pending') = 1
   from public.bank_txns where client_id = tap.v('a1')),
  'exclude and restore round-trip; unmatched lines stay in the queue'
);

-- --------------------------------------------------- review workflow
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222201');
update public.clients set require_approval = true where id = tap.v('a1');
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222202');

with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-10', 'Needs review') returning id
) insert into tap.ctx select 'je1', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je1'), tap.v('a1'), 1, tap.v('acc_rent'), 75, 0),
  (tap.v('je1'), tap.v('a1'), 2, tap.v('acc_cash'), 0, 75);
select throws_like(
  $$ select public.post_entry(tap.v('je1')) $$,
  '%requires review%',
  'under the approval regime staff cannot post directly'
);
select public.submit_entry(tap.v('je1'));
select is(
  (select status from public.journal_entries where id = tap.v('je1')),
  'submitted', 'staff submit a draft for review'
);
update public.journal_entries set memo = 'tampered' where id = tap.v('je1');
select is(
  (select memo from public.journal_entries where id = tap.v('je1')),
  'Needs review', 'a submitted entry is locked against API edits'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.post_entry(tap.v('je1')) $$,
  'a firm admin approves by posting the submitted entry'
);

select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222202');
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-11', 'Send back') returning id
) insert into tap.ctx select 'je2', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je2'), tap.v('a1'), 1, tap.v('acc_rent'), 10, 0),
  (tap.v('je2'), tap.v('a1'), 2, tap.v('acc_cash'), 0, 10);
select public.submit_entry(tap.v('je2'));
select throws_like(
  $$ select public.return_entry(tap.v('je2'), 'nope') $$,
  '%firm admin%',
  'staff cannot return their own submission'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222201');
select public.return_entry(tap.v('je2'), 'wrong account, use utilities');
select ok(
  (select status = 'draft' and review_note = 'wrong account, use utilities'
   from public.journal_entries where id = tap.v('je2')),
  'returning a submission reopens the draft with the review note'
);
select tap.logout();

-- document flow under approval
select tap.login('22222222-2222-4222-8222-222222222202');
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a1'), 'Rev Cust', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-12', tap.v('cust'), 'Review me') returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), '', 300);
select throws_like(
  $$ select public.issue_document(tap.v('inv1')) $$,
  '%requires review%',
  'issuing under the approval regime is gated at the posting engine'
);
select public.submit_document(tap.v('inv1'));
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.issue_document(tap.v('inv1')) $$,
  'a firm admin issues the submitted document'
);

-- ------------------------------------------------------------ attachments
select lives_ok(
  $$ insert into public.attachments (client_id, entry_id, storage_path, filename, mime, size_bytes)
     values (tap.v('a1'), tap.v('je1'),
             tap.v('a1') || '/deadbeef-receipt.pdf', 'receipt.pdf', 'application/pdf', 1024) $$,
  'an attachment links to a posted entry'
);
select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('attachments', tap.v('a1') || '/deadbeef-receipt.pdf') $$,
  'storage accepts an object under the client''s own prefix'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_ok(
  $$ insert into public.attachments (client_id, entry_id, storage_path, filename)
     values (tap.v('a1'), tap.v('je1'), tap.v('a1') || '/hax.pdf', 'hax.pdf') $$,
  '42501', null,
  'a client viewer cannot attach files'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222205');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('attachments', tap.v('a1') || '/crossfirm.pdf') $$,
  '42501', null,
  'firm B cannot write into firm A''s attachment prefix'
);
select tap.logout();

-- ------------------------------------------------------- audit + dashboard
select tap.login('22222222-2222-4222-8222-222222222201');
select ok(
  (select count(*) > 0 from public.audit_log
   where client_id = tap.v('a1') and table_name = 'journal_entries'),
  'the audit log now covers journal activity'
);
select ok(
  (select pending_bank = 2 and submitted = 0
   from public.practice_dashboard() where client_id = tap.v('a1')),
  'the practice dashboard counts the live queue for the client'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222205');
select is(
  (select count(*) from public.practice_dashboard() where client_id = tap.v('a1')),
  0::bigint,
  'firm B''s practice dashboard never shows firm A clients'
);
select tap.logout();

-- P4-10: import_bank_txns input guards (Phase 2 security hardening)
select tap.login('22222222-2222-4222-8222-222222222202');  -- staff_a, assigned a1
select throws_like(
  $$ select public.import_bank_txns(tap.v('a1'), tap.v('acc_cash'), '{}'::jsonb) $$,
  '%must be a JSON array%',
  'P4-10: a non-array rows payload is rejected with a clear error, not a raw exception'
);
select throws_like(
  $$ select public.import_bank_txns(tap.v('a1'), tap.v('acc_cash'),
       (select jsonb_agg(jsonb_build_object('d', '2026-08-01', 'm', 'x', 'a', 1))
        from generate_series(1, 5001))) $$,
  '%too many rows%',
  'P4-10: an over-cap import (>5000 rows) is rejected'
);
select tap.logout();

select * from finish();
rollback;

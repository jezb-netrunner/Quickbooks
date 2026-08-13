-- Inventory: FIFO layers and COGS agree with the GL to the centavo, stock
-- can never go negative, voids restore or retract stock safely, and the new
-- purchase/expense documents post their proper shapes.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(22);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_cogs',  id from public.accounts where client_id = tap.v('a1') and code = '5000';
insert into tap.ctx select 'acc_inv',   id from public.accounts where client_id = tap.v('a1') and code = '1200';
insert into tap.ctx select 'acc_cap',   id from public.accounts where client_id = tap.v('a1') and code = '3000';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222202');
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a1'), 'Inv Cust', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a1'), 'Inv Vend', 'vendor') returning id
) insert into tap.ctx select 'vend', id from c;
with i as (
  insert into public.items (client_id, sku, name, uom, income_account_id, sales_price, purchase_cost)
  values (tap.v('a1'), 'WIDGET', 'Widget', 'pc', tap.v('acc_sales'), 25.00, 10.00) returning id
) insert into tap.ctx select 'item', id from i;

-- P1: purchase on account — 10 @ 10.00: DR 1200 100 / CR AP 100, one layer
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'purchase', date '2026-08-01', date '2026-08-20', tap.v('vend'), 'Batch 1') returning id
) insert into tap.ctx select 'pr1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('pr1'), tap.v('a1'), 1, tap.v('acc_inv'), 'Widgets', 100.00, tap.v('item'), 10);
select is((select public.issue_document(tap.v('pr1'))), 1::bigint, 'the purchase issues as PR-1');
select ok(
  (select sum(l.debit) filter (where l.account_id = tap.v('acc_inv')) = 100.00
      and sum(l.credit) filter (where a.code = '2000') = 100.00
   from public.journal_lines l
   join public.accounts a on a.id = l.account_id
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('pr1')),
  'the purchase posts DR Inventory 100 / CR AP 100'
);
select is(
  (select qty_remaining from public.inventory_layers where source_document_id = tap.v('pr1')),
  10.0000::numeric(18,4),
  'a FIFO layer of 10 units exists'
);

-- P2: purchase appears in AP open items ('payable')
select is(
  (select balance from public.open_items(tap.v('a1'), 'payable', date '2026-08-31')
   where document_id = tap.v('pr1')),
  100.00::numeric(18,2),
  'the purchase is payable at its gross'
);

-- P3: second layer at a higher cost — 5 @ 14.00 (cash purchase)
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'purchase', date '2026-08-05', tap.v('vend'), tap.v('acc_cash'), 'Batch 2 cash') returning id
) insert into tap.ctx select 'pr2', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('pr2'), tap.v('a1'), 1, tap.v('acc_inv'), 'Widgets', 70.00, tap.v('item'), 5);
select public.issue_document(tap.v('pr2'));
select ok(
  (select sum(l.credit) filter (where l.account_id = tap.v('acc_cash')) = 70.00
   from public.journal_lines l
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('pr2')),
  'a cash purchase credits the bank account directly'
);
select is(
  (select count(*) from public.open_items(tap.v('a1'), 'payable', date '2026-08-31')
   where document_id = tap.v('pr2')),
  0::bigint,
  'a cash purchase never appears in AP'
);

-- P4: sale of 12 crosses the layer boundary: 10 @ 10 + 2 @ 14 = 128 COGS
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-10', tap.v('cust'), 'Sell 12') returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), 'Widgets', 300.00, tap.v('item'), 12);
select public.issue_document(tap.v('inv1'));
select ok(
  (select sum(l.debit) filter (where l.account_id = tap.v('acc_cogs')) = 128.00
      and sum(l.credit) filter (where l.account_id = tap.v('acc_inv')) = 128.00
      and sum(l.credit) filter (where l.account_id = tap.v('acc_sales')) = 300.00
   from public.journal_lines l
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('inv1')),
  'FIFO COGS crosses the layer boundary: 10@10 + 2@14 = 128, revenue 300'
);

-- P5: valuation ties to the GL 1200 balance to the centavo
select is(
  (select value from public.inventory_valuation(tap.v('a1')) where sku = 'WIDGET'),
  42.00::numeric(18,2),
  'valuation shows the 3 remaining units at 14 = 42'
);
select ok(
  (select coalesce(sum(v.value), 0) =
          (select coalesce(sum(l.debit - l.credit), 0)
           from public.journal_lines l
           join public.journal_entries e on e.id = l.entry_id
           where e.client_id = tap.v('a1') and e.status = 'posted'
             and l.account_id = tap.v('acc_inv'))
   from public.inventory_valuation(tap.v('a1')) v),
  'THE INVARIANT: total valuation equals the 1200 GL balance'
);

-- P6: stock cannot go negative
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-11', tap.v('cust'), 'Oversell') returning id
) insert into tap.ctx select 'inv_over', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('inv_over'), tap.v('a1'), 1, tap.v('acc_sales'), 'Widgets', 100.00, tap.v('item'), 4);
select throws_like(
  $$ select public.issue_document(tap.v('inv_over')) $$,
  '%stock cannot go negative%',
  'selling 4 with 3 on hand is rejected'
);

-- P7: voiding the sale puts the stock back
select public.void_document(tap.v('inv1'));
select is(
  (select qty_on_hand from public.inventory_valuation(tap.v('a1')) where sku = 'WIDGET'),
  15.0000::numeric(18,4),
  'voiding the invoice restores all 12 units (15 on hand)'
);
select ok(
  (select coalesce(sum(v.value), 0) =
          (select coalesce(sum(l.debit - l.credit), 0)
           from public.journal_lines l
           join public.journal_entries e on e.id = l.entry_id
           where e.client_id = tap.v('a1') and e.status = 'posted'
             and l.account_id = tap.v('acc_inv'))
   from public.inventory_valuation(tap.v('a1')) v),
  'the invariant survives the void'
);

-- P8: a purchase with sold stock cannot be voided
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-12', tap.v('cust'), 'Sell 1') returning id
) insert into tap.ctx select 'inv2', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('inv2'), tap.v('a1'), 1, tap.v('acc_sales'), 'Widget', 25.00, tap.v('item'), 1);
select public.issue_document(tap.v('inv2'));
select throws_like(
  $$ select public.void_document(tap.v('pr1')) $$,
  '%already been sold%',
  'a purchase whose stock has been sold refuses to void'
);

-- P9: exhaustion takes the exact residual — no stranded centavos.
-- 3 units worth exactly 1.00 (unit cost 0.333333…): per-unit rounding gives
-- 0.33 + 0.33, and the exhausting sale MUST take the remaining 0.34.
with i as (
  insert into public.items (client_id, sku, name, income_account_id)
  values (tap.v('a1'), 'PENNY', 'Penny item', tap.v('acc_sales')) returning id
) insert into tap.ctx select 'penny', id from i;
select public.post_stock_adjustment(tap.v('a1'), tap.v('penny'), date '2026-08-13', 3, 0.3333333, tap.v('acc_cap'), 'Opening');
do $sell$
declare
  v_doc uuid;
  i int;
begin
  for i in 1..3 loop
    insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
    values (tap.v('a1'), 'invoice', date '2026-08-14', tap.v('cust'), 'Penny ' || i) returning id into v_doc;
    insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
    values (v_doc, tap.v('a1'), 1, tap.v('acc_sales'), '', 1.00, tap.v('penny'), 1);
    perform public.issue_document(v_doc);
  end loop;
end $sell$;
select is(
  (select value from public.inventory_valuation(tap.v('a1')) where sku = 'PENNY'),
  0.00::numeric(18,2),
  'an exhausted layer holds exactly zero value — rounding strands nothing'
);
select ok(
  (select coalesce(sum(v.value), 0) =
          (select coalesce(sum(l.debit - l.credit), 0)
           from public.journal_lines l
           join public.journal_entries e on e.id = l.entry_id
           where e.client_id = tap.v('a1') and e.status = 'posted'
             and l.account_id = tap.v('acc_inv'))
   from public.inventory_valuation(tap.v('a1')) v),
  'the invariant holds through fractional-cost exhaustion'
);

-- P10: negative adjustment (shrinkage) consumes FIFO and posts the write-off
select lives_ok(
  $$ select public.post_stock_adjustment(tap.v('a1'), tap.v('item'), date '2026-08-15', -2, null, tap.v('acc_rent'), 'Shrinkage') $$,
  'a negative adjustment posts'
);
select is(
  (select qty_on_hand from public.inventory_valuation(tap.v('a1')) where sku = 'WIDGET'),
  12.0000::numeric(18,4),
  'shrinkage of 2 leaves 12 on hand'
);

-- P11: expense document — DR rent, CR cash, no AP involved
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'expense', date '2026-08-16', tap.v('vend'), tap.v('acc_cash'), 'Parking') returning id
) insert into tap.ctx select 'exp1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('exp1'), tap.v('a1'), 1, tap.v('acc_rent'), 'Parking fees', 50.00);
select public.issue_document(tap.v('exp1'));
select ok(
  (select sum(l.debit) filter (where l.account_id = tap.v('acc_rent')) = 50.00
      and sum(l.credit) filter (where l.account_id = tap.v('acc_cash')) = 50.00
   from public.journal_lines l
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('exp1')),
  'an expense debits the cost and credits cash directly'
);

-- P12: item lines are rejected outside invoices and purchases
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id)
  values (tap.v('a1'), 'bill', date '2026-08-17', date '2026-08-30', tap.v('vend')) returning id
) insert into tap.ctx select 'bill_bad', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, item_id, qty)
values (tap.v('bill_bad'), tap.v('a1'), 1, tap.v('acc_rent'), '', 10.00, tap.v('item'), 1);
select throws_like(
  $$ select public.issue_document(tap.v('bill_bad')) $$,
  '%receive inventory with a purchase%',
  'a bill cannot carry item lines'
);

-- P13: a payment settles the purchase through the payable side
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'disbursement', date '2026-08-18', tap.v('vend'), tap.v('acc_cash'), 'Pay PR-1') returning id
) insert into tap.ctx select 'pay1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('pay1'), tap.v('pr1'), 100.00);
select lives_ok(
  $$ select public.issue_document(tap.v('pay1')) $$,
  'a payment applies to a purchase'
);
select is(
  (select count(*) from public.open_items(tap.v('a1'), 'payable', date '2026-08-31')),
  0::bigint,
  'the payable side is clear after the payment'
);

-- P14: hand-posting 1200 on a non-item line is rejected
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id)
  values (tap.v('a1'), 'bill', date '2026-08-19', date '2026-08-30', tap.v('vend')) returning id
) insert into tap.ctx select 'bill_1200', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('bill_1200'), tap.v('a1'), 1, tap.v('acc_inv'), 'Sneaky inventory', 10.00);
select throws_like(
  $$ select public.issue_document(tap.v('bill_1200')) $$,
  '%pick an item instead of posting to 1200%',
  'the inventory control account is closed to non-item lines'
);
select tap.logout();

select * from finish();
rollback;

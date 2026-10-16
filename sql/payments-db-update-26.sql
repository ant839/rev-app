-- Payments db update 26 (16 Oct 2026). Missed payment push now points athletes at "Run payment again".
-- Also: Stripe's card page is cards only via the "Rev app cards only" payment method configuration (made by the billing function).
-- Missed payment emails go out from the billing function through Resend once RESEND_API_KEY is set (coach), and to athletes once RESEND_FROM is a verified sender.
create or replace function private.notify_charge() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare nm text; coaches uuid[];
begin
  if new.status = 'failed' and (old.status is distinct from 'failed') then
    select coalesce(nullif(full_name, ''), email) into nm from public.profiles where id = new.profile_id;
    perform private.push_out(array[new.profile_id], 'Your payment didn''t go through',
      'Your $' || to_char(new.amount_cents / 100.0, 'FM999990.00') || ' membership payment was missed. Once the money is in your account, tap here and Run payment again.',
      'https://ant839.github.io/rev-app/#pay', null, 'pay-' || new.id, null);
    select array_agg(id) into coaches from public.profiles where role = 'coach';
    perform private.push_out(coaches, 'Payment failed', nm || ': $' || to_char(new.amount_cents / 100.0, 'FM999990.00') || coalesce(' (' || left(new.failure, 80) || ')', ''),
      null, 'https://ant839.github.io/rev-app/admin.html#memberships', 'payfail-' || new.id, 'payments');
  end if;
  return new;
exception when others then
  raise warning 'charge push failed: %', sqlerrm; return new;
end $$;

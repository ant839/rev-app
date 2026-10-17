# Membership agreements (built 17 Oct 2026) — NOT LIVE YET

Status: Ant (17 Oct): not on people's apps yet. Switch private.app_config agreements_live = false (see sql/agreements-db-update-30.sql for going live). Coaches see everything; athletes see nothing new; Join is coaches only; minimum term / fee / cooling-off rules off; waiver v1 active, Gymdesk waiver saved as v2.

Source: Ant's Gymdesk agreements (Members > Documents, last updated Nov 2025 / Jan 2026), copied and updated for the app.
Texts live in membership_plans.agreement_body (version in agreement_version); generator: agreements/make_agreements.py, output agreements/membership-agreements-v1.json in ant839/rev-app.
Waiver: app waiver v2 = Gymdesk "Waiver and Release Agreement" word for word (v1 retired 17 Oct, so Beta Testers who signed v1 are asked to sign again).

## Ant's decisions (17 Oct 2026)
- Copy Gymdesk's wording. New joiners sign when joining; existing athletes sign when Ant moves them across (prompt in the app once they have a membership).
- Cards, not direct debit. Prices "$X per week, billed fortnightly".
- Inclusions match the app plans (Barbell Club Gold: Barbell Club + Tue/Thu Engine + Saturday FNDN; FNDN Gold: FNDN classes + Saturday Barbell Club). Open gym 4am to 10pm and sauna discount kept.
- Minimum terms kept and enforced: 12 weeks Barbell Club Gold, Barbell Club 3 Day, Platinum; 4 weeks FNDN Gold.
- Inside the 12 week term: can cancel with 30 days' notice and a flat $200 early cancellation fee (waived with medical documentation; Ant ticks "Waive the fee" when approving). FNDN inside 4 weeks: only medical or relocation over 20 km, Ant decides (app blocks it, says message Coach Ant).
- After the minimum term: 14 days' notice, no fee. Memberships finish on a Sunday.
- Holds: 14 days' notice for everyone, whole weeks, min 1 week, max 8 weeks per calendar year, not inside the minimum term (medical/compassionate: message Ant).
- Whole weeks Monday to Sunday, no partial weeks: start week and finish week charged in full.
- $25 dishonour fee dropped.

## WA Fitness Industry Code (Consumer Protection guide, checked 17 Oct 2026)
- 7 day cooling-off on new agreements: added (app lets them cancel from today with no notice inside 7 days of signing).
- Cancellation notice can't be more than 30 days: 30 days is the most used (inside the 12 week term only).
- Termination fee only if stated in the agreement: stated ($200).
- Business name, address and email in the agreement: added (5/146 Balcatta Road, Balcatta WA; ant@revbbc.com.au).
- Notice before the initial term ends (Fair Trading (Fitness Industry Code of Practice) Regulations 2020, clause 17): only required when the initial term is more than 6 months. Rev's longest minimum term is 12 weeks, so Ant removed the reminder (17 Oct 2026): clause 7(f) taken out of the agreements and the 'min-term-reminders' cron job unscheduled (private.min_term_reminders() is still in the database, unused). If a plan ever gets an initial term over 6 months, written notice at least 2 months before it ends is required again, and the agreement must state that date.
- Changes need both parties' agreement: section 12 rewritten (they re-sign updated agreements in the app; can cancel without the fee if they don't agree).
- Respond to cancellation requests within 7 days: stated in section 7.
- Not covered: a copy of centre rules (Code says agreements must include one), ABN. Ant should get the final wording checked; Claude isn't a lawyer.

## How it works in the app
- public.agreement_for(plan, start): text with {price} {start} {min_end} filled. public.sign_agreement(plan, name, agent, start): saves an exact copy in membership_agreements (profile, plan, membership, version, title, body, signed_name, signed_at, user_agent).
- Join: plan + start day -> "Read agreement and join" -> agreement sheet (also signs the waiver if needed) -> Stripe. The billing function refuses 'join' without a signed agreement for that plan version, and links it to the new membership.
- My membership card: minimum term line, "Agreement: Signed <date> · View" or "Read and sign your agreement". Home shows a "To sign" card when unsigned.
- Hold or cancel screen: explains minimum term, fee, cooling-off; only offers allowed weeks; server enforces the same (request_hold_cancel).
- Early cancel fee: membership_requests.fee_cents; on approval (trigger private.request_fee) a pending billing_charges row "early cancellation fee" is added for the next 6am run if they're billed through the app and have a card; Gymdesk-billed: Ant charges it himself.
- REV Admin: athlete sheet shows agreement signed / not signed (View); pending cancel requests show the fee and a "Waive the fee (medical)" tick; Plans and prices has Minimum term weeks and Early cancel fee per plan.
- Tested 17 Oct (rolled back): price/start/min term filled; cooling-off cancel today OK; inside term ~20 days refused with the earliest date; 30+ days accepted with $200 fee; approval created the $200 charge row and set the last day; hold inside term refused.

## Barbell Club Gold agreement (as signed in the app; other plans differ in inclusions, minimum term and section 7)

BARBELL CLUB GOLD MEMBERSHIP AGREEMENT

Kapcorp Enterprises Pty Ltd, trading as Rev Barbell Club and FNDN
5/146 Balcatta Road, Balcatta WA
Email: ant@revbbc.com.au

My Membership

Membership: Barbell Club Gold

Price: {price} per week, billed fortnightly

Start date: {start}

Minimum term: 12 weeks, ending {min_end}

Payments: charged to my saved card every second Wednesday

Early cancellation fee (inside the minimum term): $200

1. Agreement Overview

By signing this agreement in the Rev app, I enter into a Barbell Club Gold Membership Agreement with Kapcorp Enterprises Pty Ltd, trading as Rev Barbell Club and FNDN (“the Club”). This document outlines the terms and conditions under which I access the Club’s facilities, coaching and services.

2. Membership Term and Inclusions

a. The minimum membership term is twelve (12) weeks from the first payment date.

b. Memberships continue on a rolling basis after the minimum term unless cancelled under Section 7.

c. The Barbell Club Gold Membership includes:

All Barbell Club coached sessions.

FNDN Engine classes (Tuesday and Thursday) and the Saturday FNDN session.

Full access to the Rev Barbell Club Base Program in the Rev app.

Open Gym access from 4:00am to 10:00pm, seven days a week, via a personal access code.

Discounted sauna access during staffed hours.

d. Athletes are responsible for keeping their personal access code and app login private and using them correctly.

e. The Club may change session times, schedules or facility access with reasonable notice.

3. Payments and Billing

a. Membership fees are {price} per week, billed fortnightly.

b. Fees are charged to the card saved in the Rev app every second Wednesday, for that Monday to Sunday fortnight. The first payment is on the Wednesday of my first week.

c. All prices include GST and cover the inclusions listed in Section 2.

d. Memberships run in whole weeks, Monday to Sunday. There are no partial weeks: the week I start and the week I finish are charged in full, holds and cancellations go by whole weeks, and weeks on hold are not charged.

e. Athletes are responsible for making sure there are enough funds available on their card on the billing date.

f. Memberships are personal and non-transferable.

g. Athletes can update their card in the Rev app at any time (menu, My membership).

4. Failed or Missed Payments

a. If a payment fails, the Club will let me know in the Rev app and may retry the payment automatically. I can run the payment again or update my card in the app at any time.

b. If payments remain outstanding for more than 14 days, access to training, coaching and programming may be suspended until the account is up to date.

c. The Club may forward unresolved accounts to a collections agency.

d. The Club is not responsible for any bank or card provider fees caused by failed payments.

5. Membership Holds

a. Holds are taken in whole weeks (Monday to Sunday), for a minimum of 1 week and a maximum of 8 weeks per calendar year.

b. Hold requests must be made in the Rev app (or by email) with at least 14 days’ notice.

c. Holds cannot be backdated or applied retrospectively.

d. Memberships cannot be placed on hold during the initial 12-week term, except for verified medical or compassionate reasons approved by the Club.

e. Weeks on hold are not charged.

6. Refund Policy

a. Membership fees are non-refundable, except where required under the Australian Consumer Law (ACL).

b. Refunds will only be issued where the Club fails to deliver a paid service or under statutory consumer guarantees.

c. Non-attendance, change of mind or voluntary withdrawal do not qualify for refunds.

7. Membership Cancellations

a. Cooling-off: I can cancel this agreement within 7 days of signing it, for any reason, by telling the Club in the Rev app or by email. Any payment made will be refunded, less a charge for classes or services already used.

b. After the initial 12-week minimum term, I can cancel at any time with at least 14 days’ notice.

c. Cancellations must be made in the Rev app (preferred) or by email to the Club, and will not be accepted verbally or through social media. The Club will respond within 7 days.

d. Memberships finish at the end of a week, on a Sunday. Payments that fall due within the notice period will still be processed, and payments stop automatically after my last day.

e. Inside the initial 12-week term, I can cancel with at least 30 days’ notice and a $200 early cancellation fee, charged to my saved card once the cancellation is approved. The fee is waived if I provide medical documentation confirming serious injury or illness.

f. If an athlete stops attending without cancelling, billing continues until the cancellation is received and processed.

8. Personal Training (PT) Sessions

a. Personal Training sessions must be paid in advance or as part of a packaged membership.

b. 24 hours’ notice is required to cancel or reschedule a session. Late cancellations or no-shows will be charged in full.

c. PT sessions expire 90 days from purchase unless otherwise agreed in writing.

d. PT sessions are non-transferable and non-refundable.

9. Facility Access and Use

a. Gold athletes receive Open Gym access (4:00am to 10:00pm) via an individual access code.

b. Access is for the athlete only; sharing or misuse of codes will result in suspension or termination.

c. The Club maintains equipment regularly but is not liable for injuries resulting from misuse or failure to follow instructions.

d. Athletes must follow all posted safety rules and staff instructions at all times.

e. Open Gym use is covered by the Rev Barbell Club Waiver and Release Agreement.

10. Health, Safety and Conduct

a. Athletes must disclose any medical or physical conditions that may affect training.

b. The Club may restrict access if an athlete is deemed unfit or unsafe to train.

c. Athletes must maintain respectful conduct, appropriate hygiene and proper training attire.

d. Any behaviour that is unsafe, abusive or disruptive may result in immediate termination without refund.

11. Privacy and Data

a. The Club collects and stores personal information in accordance with the Privacy Act 1988 (Cth) and the Australian Privacy Principles.

b. Athlete information is used only for administrative, payment and safety purposes.

c. Data may be shared with third-party software (e.g. payment processors, app providers) solely for operational needs. Card details are held by the payment processor (Stripe), not by the Club.

12. Changes to Terms and Services

The Club will give at least 14 days’ notice of any change to these Terms, in the Rev app or by email. Changes to this agreement need the agreement of both parties: I will be asked to read and sign the updated agreement in the Rev app, and if I don’t agree to the change I can cancel without an early cancellation fee.

13. Liability and Waiver Reference

By accepting this Agreement, I acknowledge that I have also read and agreed to the Rev Barbell Club Waiver and Release Agreement, which forms part of this contract. I understand that physical training carries inherent risks and I accept full responsibility for my participation.

14. Governing Law and Dispute Resolution

a. This Agreement is governed by the laws of Western Australia.

b. Both parties agree to attempt informal resolution of any disputes before formal action.

c. Any unresolved disputes will be subject to the jurisdiction of the courts of Western Australia.

Athlete Acknowledgement

I have read, understood and agree to the above Barbell Club Gold Membership Agreement.

This agreement complies with the Fair Trading (Fitness Industry Code of Practice 2020 – WA).
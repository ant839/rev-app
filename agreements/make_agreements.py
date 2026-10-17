# Rev membership agreements, from Ant's Gymdesk agreements (Nov 2025), updated 17 Oct 2026 for the app:
# cards not direct debit, inclusions match the app plans, minimum terms enforced, holds 14 days' notice for everyone, no dishonour fee.
# Ant 17 Oct: explain whole weeks (Mon to Sun, no partial weeks); 12 week plans can be cancelled inside the minimum term with
# 30 days' notice and a $200 early cancellation fee. WA Fitness Industry Code: 7 day cooling-off, business address and email,
# contact before the fixed term ends, changes need both parties' agreement, notice no more than 30 days.
PLANS = {
 'Barbell Club Gold': dict(min=12, fee=200, inc=[
   "All Barbell Club coached sessions.",
   "FNDN Engine classes (Tuesday and Thursday) and the Saturday FNDN session.",
   "Full access to the Rev Barbell Club Base Program in the Rev app.",
   "Open Gym access from 4:00am to 10:00pm, seven days a week, via a personal access code.",
   "Discounted sauna access during staffed hours."], extra_inc=[], fac_open="Gold athletes receive Open Gym access (4:00am to 10:00pm) via an individual access code.", fndn=False),
 'Barbell Club 3 Day': dict(min=12, fee=200, inc=[
   "Up to three (3) sessions a week in total, from Barbell Club coached sessions, FNDN Engine classes (Tuesday and Thursday) and the Saturday FNDN session.",
   "Full access to the Rev Barbell Club Base Program in the Rev app.",
   "Open Gym access from 4:00am to 10:00pm, seven days a week, via a personal access code, within the three (3) visits a week.",
   "Discounted sauna access during staffed hours."],
   extra_inc=["“Three visits a week” includes all gym entry: coached sessions, classes and Open Gym. Additional visits may be charged at the casual rate or need an upgrade to Barbell Club Gold."],
   fac_open="3 Day athletes receive Open Gym access (4:00am to 10:00pm) via an individual access code, within three (3) total visits a week.", fndn=False),
 'FNDN Gold': dict(min=4, fee=None, inc=[
   "All FNDN classes.",
   "Full access to the FNDN programming in the Rev app.",
   "The Saturday Barbell Club session.",
   "Open Gym access from 4:00am to 10:00pm, seven days a week, via a personal access code.",
   "Discounted sauna access during staffed hours."], extra_inc=[], fac_open="FNDN Gold athletes receive Open Gym access (4:00am to 10:00pm) via an individual access code.", fndn=True),
 'Platinum': dict(min=12, fee=200, inc=[
   "All Barbell Club coached sessions.",
   "All FNDN classes.",
   "The option of fully customised programming in the Rev app.",
   "Open Gym access from 4:00am to 10:00pm, seven days a week, via a personal access code.",
   "Discounted sauna access during staffed hours."], extra_inc=[], fac_open="Platinum athletes receive Open Gym access (4:00am to 10:00pm) via an individual access code.", fndn=False),
}
WORDS={4:'four',12:'twelve'}
def L(xs, start='a'):
    return '\n\n'.join(f"{chr(ord(start)+i)}. {x}" for i,x in enumerate(xs))
def body(name, p):
    m=p['min']; mw=f"{WORDS[m]} ({m}) weeks"
    s=[]
    s.append(f"{name.upper()} MEMBERSHIP AGREEMENT\n\nKapcorp Enterprises Pty Ltd, trading as Rev Barbell Club and FNDN\n5/146 Balcatta Road, Balcatta WA\nEmail: ant@revbbc.com.au")
    s.append("My Membership\n\nMembership: "+name+"\n\nPrice: {price} per week, billed fortnightly\n\nStart date: {start}\n\nMinimum term: "+f"{m} weeks, ending {{min_end}}"+"\n\nPayments: charged to my saved card every second Wednesday"+(f"\n\nEarly cancellation fee (inside the minimum term): ${p['fee']}" if p['fee'] else ""))
    s.append(f"1. Agreement Overview\n\nBy signing this agreement in the Rev app, I enter into a {name} Membership Agreement with Kapcorp Enterprises Pty Ltd, trading as Rev Barbell Club and FNDN (“the Club”). This document outlines the terms and conditions under which I access the Club’s facilities, coaching and services.")
    inc='\n\n'.join(p['inc'])
    rest=[*p['extra_inc'], "Athletes are responsible for keeping their personal access code and app login private and using them correctly.", "The Club may change session times, schedules or facility access with reasonable notice."]
    s.append(f"2. Membership Term and Inclusions\n\na. The minimum membership term is {mw} from the first payment date.\n\nb. Memberships continue on a rolling basis after the minimum term unless cancelled under Section 7.\n\nc. The {name} Membership includes:\n\n{inc}\n\n"+L(rest,'d'))
    s.append("3. Payments and Billing\n\n"+L([
      "Membership fees are {price} per week, billed fortnightly.",
      "Fees are charged to the card saved in the Rev app every second Wednesday, for that Monday to Sunday fortnight. The first payment is on the Wednesday of my first week.",
      "All prices include GST and cover the inclusions listed in Section 2.",
      "Memberships run in whole weeks, Monday to Sunday. There are no partial weeks: the week I start and the week I finish are charged in full, holds and cancellations go by whole weeks, and weeks on hold are not charged.",
      "Athletes are responsible for making sure there are enough funds available on their card on the billing date.",
      "Memberships are personal and non-transferable.",
      "Athletes can update their card in the Rev app at any time (menu, My membership)."]))
    s.append("4. Failed or Missed Payments\n\n"+L([
      "If a payment fails, the Club will let me know in the Rev app and may retry the payment automatically. I can run the payment again or update my card in the app at any time.",
      "If payments remain outstanding for more than 14 days, access to training, coaching and programming may be suspended until the account is up to date.",
      "The Club may forward unresolved accounts to a collections agency.",
      "The Club is not responsible for any bank or card provider fees caused by failed payments."]))
    s.append("5. Membership Holds\n\n"+L([
      "Holds are taken in whole weeks (Monday to Sunday), for a minimum of 1 week and a maximum of 8 weeks per calendar year.",
      "Hold requests must be made in the Rev app (or by email) with at least 14 days’ notice.",
      "Holds cannot be backdated or applied retrospectively.",
      f"Memberships cannot be placed on hold during the initial {m}-week term, except for verified medical or compassionate reasons approved by the Club.",
      "Weeks on hold are not charged."]))
    s.append("6. Refund Policy\n\n"+L([
      "Membership fees are non-refundable, except where required under the Australian Consumer Law (ACL).",
      "Refunds will only be issued where the Club fails to deliver a paid service or under statutory consumer guarantees.",
      "Non-attendance, change of mind or voluntary withdrawal do not qualify for refunds."]))
    exc = "The athlete provides medical documentation confirming serious injury or illness; or\n\nThe athlete permanently relocates more than 20 km from the Club, with proof of address change." if p['fndn'] else "The athlete provides medical documentation confirming serious injury or illness."
    canc=[
      "Cooling-off: I can cancel this agreement within 7 days of signing it, for any reason, by telling the Club in the Rev app or by email. Any payment made will be refunded, less a charge for classes or services already used.",
      f"After the initial {m}-week minimum term, I can cancel at any time with at least 14 days’ notice.",
      "Cancellations must be made in the Rev app (preferred) or by email to the Club, and will not be accepted verbally or through social media. The Club will respond within 7 days.",
      "Memberships finish at the end of a week, on a Sunday. Payments that fall due within the notice period will still be processed, and payments stop automatically after my last day."]
    if p['fee']:
      canc.append(f"Inside the initial {m}-week term, I can cancel with at least 30 days’ notice and a ${p['fee']} early cancellation fee, charged to my saved card once the cancellation is approved. The fee is waived if I provide medical documentation confirming serious injury or illness.")
    else:
      canc.append(f"Cancellations during the initial {m}-week term will only be approved if:\n\n{exc}")
    canc += [f"Before my minimum term ends, the Club will remind me in the Rev app so I can cancel without a fee if I choose.",
      "If an athlete stops attending without cancelling, billing continues until the cancellation is received and processed."]
    s.append("7. Membership Cancellations\n\n"+L(canc))
    s.append("8. Personal Training (PT) Sessions\n\n"+L([
      "Personal Training sessions must be paid in advance or as part of a packaged membership.",
      "24 hours’ notice is required to cancel or reschedule a session. Late cancellations or no-shows will be charged in full.",
      "PT sessions expire 90 days from purchase unless otherwise agreed in writing.",
      "PT sessions are non-transferable and non-refundable."]))
    fac=[p['fac_open'], "Access is for the athlete only; sharing or misuse of codes will result in suspension or termination."]
    if p['fndn']: fac += ["Athletes may use all areas of the gym outside of scheduled class times.", "During class times, group training areas and Barbell Club platforms in use are reserved and cannot be used for independent training."]
    fac += ["The Club maintains equipment regularly but is not liable for injuries resulting from misuse or failure to follow instructions.", "Athletes must follow all posted safety rules and staff instructions at all times.", "Open Gym use is covered by the Rev Barbell Club Waiver and Release Agreement."]
    s.append("9. Facility Access and Use\n\n"+L(fac))
    s.append("10. Health, Safety and Conduct\n\n"+L([
      "Athletes must disclose any medical or physical conditions that may affect training.",
      "The Club may restrict access if an athlete is deemed unfit or unsafe to train.",
      "Athletes must maintain respectful conduct, appropriate hygiene and proper training attire.",
      "Any behaviour that is unsafe, abusive or disruptive may result in immediate termination without refund."]))
    s.append("11. Privacy and Data\n\n"+L([
      "The Club collects and stores personal information in accordance with the Privacy Act 1988 (Cth) and the Australian Privacy Principles.",
      "Athlete information is used only for administrative, payment and safety purposes.",
      "Data may be shared with third-party software (e.g. payment processors, app providers) solely for operational needs. Card details are held by the payment processor (Stripe), not by the Club."]))
    s.append("12. Changes to Terms and Services\n\nThe Club will give at least 14 days’ notice of any change to these Terms, in the Rev app or by email. Changes to this agreement need the agreement of both parties: I will be asked to read and sign the updated agreement in the Rev app, and if I don’t agree to the change I can cancel without an early cancellation fee.")
    s.append("13. Liability and Waiver Reference\n\nBy accepting this Agreement, I acknowledge that I have also read and agreed to the Rev Barbell Club Waiver and Release Agreement, which forms part of this contract. I understand that physical training carries inherent risks and I accept full responsibility for my participation.")
    s.append("14. Governing Law and Dispute Resolution\n\n"+L([
      "This Agreement is governed by the laws of Western Australia.",
      "Both parties agree to attempt informal resolution of any disputes before formal action.",
      "Any unresolved disputes will be subject to the jurisdiction of the courts of Western Australia."]))
    s.append(f"Athlete Acknowledgement\n\nI have read, understood and agree to the above {name} Membership Agreement.\n\nThis agreement complies with the Fair Trading (Fitness Industry Code of Practice 2020 – WA).")
    return '\n\n'.join(s)
import json
out={n:{'title':f"{n} Membership Agreement",'min':p['min'],'body':body(n,p)} for n,p in PLANS.items()}
json.dump(out,open('agreements.json','w'),ensure_ascii=False,indent=1)
print(out['FNDN Gold']['body'][:3000])

# Kallo Klubams CRM

The working product behind kallo.lt: members, attendance, monthly fees and automatic reminders for sports clubs and activity groups.

- **Sales demo:** `/demo/` on the website. Runs fully in the browser with sample data, no backend. It is the reference design for the real app.
- **Database:** `supabase/schema.sql` (tables, row-level security, billing helpers).

## Architecture

| Part | Choice | Why |
|---|---|---|
| Database, login, files | Supabase, **EU region** | Already used by Kallo; Postgres + auth + row-level security out of the box |
| Web app (owner, admin, coach) | Vite + React + TypeScript, hosted on Netlify at `app.kallo.lt` | One codebase for desktop and phone; installable as a PWA before native apps |
| Scheduled jobs | Supabase `pg_cron` + Edge Functions | Day 1 charges, day 7 and 14 reminders, daily delivery retries |
| SMS | Provider TBD (needs Lithuanian delivery and a sender name) | Cost passed through at price |
| Email | Provider TBD (EU data processing) | Free for clubs |
| Payments | Paysera payment links + webhook; bank statement import | Parents pay the club directly; Kallo never holds money |

## How money flows

1. **Day 1:** `create_monthly_charges()` makes one charge per active member, each with a short `pay_ref` such as `KS-7F3Q2`.
2. Parents get an SMS or email with the amount and either a Paysera link or the club's IBAN with the `pay_ref` as the payment purpose.
3. **Paysera webhook** → payment row → charge marked paid.
4. **Bank statement import** (CSV or ISO 20022 camt.053 from Swedbank, SEB, Luminor, Revolut):
   - match on `pay_ref` first;
   - then on amount + parent name;
   - anything left is shown to the owner to match by hand.
5. **Day 7 and 14:** reminders go only to guardians of charges still `requested` or `late`.

## Who sees what

- **Owner / admin:** everything in their club.
- **Coach:** only members and attendance of the groups they coach. No money, no messages.
- Clubs never see each other's data: every table is filtered by `club_id` through row-level security.

## Build order

1. **Accounts and import:** sign up, create club, groups, and import members and parents from Excel/CSV.
2. **Attendance:** coach link on the phone, monthly attendance sheet export.
3. **Charges and Paysera:** day-1 charges, payment links, webhook, manual "mark as paid".
4. **Reminders:** SMS and email sending, day 7 and 14 schedule, delivery log, opt-out.
5. **Bank import and matching.**
6. **Reports:** monthly summary email, NVŠ attendance export, accounting CSV.
7. **Billing for Kallo itself:** count active members per month, invoices to clubs.

Steps 1–4 are the minimum a paying club needs. 5–7 make it hard to leave.

## Data rules (from the terms)

- No personal ID codes, health data or photos.
- Notes are limited to 500 characters.
- Delete a club's data 30 days after the contract ends; backups expire 30 days later.

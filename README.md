# Kallo

> AI pokalbių robotas lietuviškiems salonams. Atsako į klausimus, rezervuoja laikus, dirba 24/7.

Landing page for **Kallo** — an AI chatbot widget that Lithuanian beauty salons and wellness venues embed on their websites. It answers customer questions from the site's own content and books appointments directly into Google Calendar.

## Live

- Production: [https://kallo.lt](https://kallo.lt)

## Stack

Plain static HTML + CSS + vanilla JavaScript. No build step. Deployed on Netlify with automatic HTTPS via Let's Encrypt.

- **Fonts**: DM Serif Display (headlines), DM Sans (body)
- **Palette**: Ink `#1A0A00`, Coral `#FF6B47`, Cream `#FFFCFA`, Blush `#FFF5F0`, Green `#1D9E75`
- **Form handling**: Netlify Forms (no backend)

## Files

- `index.html` — Full landing page (hero, features, how it works, calendar demo, pricing, testimonials, FAQ, CTA)
- `aciu.html` — Post-signup thank-you page
- `favicon.svg` — Brand mark (ink square + cream K + coral dot)

## Local preview

Just open `index.html` in a browser, or serve it with any static server:

```bash
npx http-server . -p 5173
```

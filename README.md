# mPrompto — Merchandising Dashboard (Charts)

Static, self-contained HTML dashboards for Embark merchandising analytics
(Bestseller volume & Velocity conversion), with data baked directly into each page.

## Live site
Served via GitHub Pages from `index.html`.

## Pages
- **index.html** — Velocity "Conversion Efficiency" view: previous vs current bars with a change (pp) line. (the primary dashboard)
- **index-v2.html** — same data, velocity shown with clean +/-pp change badges (no line).
- **index-top5.html** — side-by-side charts, top 5 products.
- **index-stacked.html** — stacked single-column layout.
- **index-embark.html** — EMBARK-branded KPI + charts layout.
- **index-gallery.html** — showcase of all candidate chart designs.

## Controls
Each dashboard supports:
- Period toggle: 7D / 14D / 30D
- View toggle: Categories / Products
- Category filter

## Data
Charts are driven from merchandising CSV exports (Bestseller volume + trending velocity).
The raw CSVs are intentionally not committed; the numbers are already embedded in the HTML.

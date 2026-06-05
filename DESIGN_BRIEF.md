# Tracy Design Brief — Phase 1 through Phase 2

**Owner:** Designer  
**Status:** Open (Phase 1 in progress)  
**Last updated:** 2026-06-05

This document breaks down the design work for Tracy — a personal AI dev orchestrator with a mobile-first, list-view UI powered by Phoenix LiveView + daisyUI + Tailwind CSS.

## Strategic Design Goals

1. **Mobile-first, usable on phone via Tailscale LiveView** from day one
2. **List view grouped by status** (not Kanban) — matches Matt's existing Linear habit
3. **C-Suite vibe** — cards show budget burn, worker status, cost metrics inline
4. **Dark-first with light companion** — `tracy` (dark, preferred) and `tracy-light` themes
5. **Accessibility from the start** — WCAG AA compliance, keyboard navigation, color contrast ≥4.5:1
6. **No unnecessary animations** — responsive, snappy, purposeful motion only

## Design System (Phase 1, Week 1)

### 1.1 — Color Palette & Token Documentation

**Current state:** `app.css` defines `tracy` and `tracy-light` themes using daisyUI plugin + OKLCH color space.

**Design tasks:**
- [ ] **D-1.1a** Document the theme token architecture
  - Surfaces: `base-100`, `base-200`, `base-300`, `base-content`
  - States: `primary`, `secondary`, `accent` + content variants
  - Semantic: `info`, `success`, `warning`, `error`
  - Create a public Figma file or design-tokens.md showing token → usage
  - Verify both themes meet WCAG AA contrast minimums (4.5:1 on text, 3:1 on UI)
  - Accept: Figma frame with all colors + contrast matrix; Markdown token doc

- [ ] **D-1.1b** Lock the Tyler the Creator / Spidey-inspired palette
  - Tracy cyan (primary) = current `oklch(72% 0.16 200)` in dark theme
  - Spider red (secondary) = current `oklch(58% 0.24 25)` in dark theme
  - Web blue (accent) = current `oklch(55% 0.20 250)` in dark theme
  - Verify these feel "the vibe" in live context (boardroom page)
  - Accept: Signed-off palette, no changes to app.css theme values

### 1.2 — Typography System

**Current state:** Using Tailwind's default font stack + daisyUI semantic sizes.

**Design tasks:**
- [ ] **D-1.2a** Choose and document the font family
  - Default: Tailwind's system stack (`system-ui, sans-serif`) is solid
  - Alternative: Specify a custom font (e.g., Inter, Geist, Outfit)
  - If custom, add @import to app.css and configure in tailwind.config.ts
  - Accept: Font family decision + implementation in tailwind.config.ts, screenshot of live boardroom text

- [ ] **D-1.2b** Document the type scale
  - Base sizes: 12px (label), 14px (body), 16px (subheading), 24px (heading), 32px (page title)
  - Line heights: 1.4 (dense labels), 1.5 (body), 1.6 (headings)
  - Letter spacing: tighter on headings (`tracking-tight` = -0.015em), normal on body
  - Create a typographic specimen page showing all scales
  - Accept: Type scale spreadsheet + live component page

### 1.3 — Component Spec Sheet

**Current state:** Placeholder components in boardroom.html.heex (`.panel`, `.meter`), auth flows exist but unpolished.

**Design tasks:**
- [ ] **D-1.3a** Define the base component library
  - **Button** variants: `primary` (Tracy cyan), `secondary` (red), `accent` (blue), `ghost`, `outline`, disabled states
    - Base size 44px height (touch-friendly thumb target)
    - Icon buttons 40px × 40px minimum
  - **Card** (`.rounded-box`): padding, border, shadow, hover states
  - **Badge/Pill**: status badges, worker role badges, cost indicators
  - **Input fields**: text, textarea, select (forms for comments, dispatch briefs)
  - **Checkbox/Radio**: daisyUI default + custom styling
  - **Modal/Dialog**: for confirmation, detail drill-down on mobile
  - Create Figma components or HTML component library page
  - Accept: Component Figma file + live component demo page in app

- [ ] **D-1.3b** Loading & empty states
  - Loading spinner (subtle, not animated) or skeleton cards
  - Empty state illustrations/icons + helpful text
  - Toasts/alerts for status changes (success, error, warning)
  - Accept: 3–5 empty state mockups; toast specification

## Plan List View (Phase 2, Week 1–2)

### 2.1 — List Layout & Interaction

**Current state:** Placeholder panels on boardroom.html.heex; no actual plan list yet.

**Context:** Plans are grouped by status (Triage, Backlog, In Progress, In Review, Needs Input, Done). Each status section is collapsible. Each plan shows cost, worker, and status at a glance.

**Design tasks:**
- [ ] **D-2.1a** Design the plan list view layout
  - Collapsible status sections (▼ Triage (3))
  - Each plan card shows:
    - Plan ID + title (e.g., "TRA-12 ● Fix streaming bug")
    - Worker role + cost (e.g., "Engineer $0.18/$0.50 4m elapsed")
    - Status badge (● In Progress, ◐ In Review, etc.)
    - Timestamp + [reply] link if Needs Input
  - Visual hierarchy: title largest, worker/cost secondary, timestamp tertiary
  - Touch-friendly: tap anywhere on card to drill into detail page
  - Desktop: list with clear dividers between sections
  - Mobile: full-width cards, no horizontal scroll
  - Accept: Figma frame for mobile (375px) + desktop (1200px); live prototype in Phoenix

- [ ] **D-2.1b** Status section headers & grouping
  - Header shows status name + count (e.g., "▼ In Progress (2)")
  - Collapsible toggle on the section header
  - Optional: warning icon if "Needs Input" section has items
  - Drag-to-reorder sections (if drag-drop planned), or fixed order
  - Accept: Header mockup + interaction spec

- [ ] **D-2.1c** Cost visualization
  - Inline cost display: "Engineer $0.18/$0.50" (used / cap)
  - Optional: small horizontal bar behind the text showing progress (light fill)
  - Color coding: green if under budget, yellow if 50–75%, red if ≥75%
  - Touch-friendly: tapping cost shows tooltip with remaining, cost breakdown
  - Accept: Three states (green/yellow/red) mockup + tooltip spec

### 2.2 — Plan Detail Page

**Current state:** Sketch in TRACY_PLAN_SURFACE.md; not yet built.

**Design tasks:**
- [ ] **D-2.2a** Detail page layout
  - Header: Plan ID + title + status badge (tap to change status)
  - Brief section: indented, gray text, 2–3 lines max (expandable if longer)
  - Metadata grid:
    - Worker: role + model (e.g., "Engineer-A (Sonnet)")
    - Budget: "$0.18 used of $0.50 cap" with progress bar
    - Started: "14:04" + Elapsed: "4m 12s"
    - Scope (optional): files + dispatch chain
  - Comments thread: list of timestamped comments with author
  - Action buttons: [Approve push] [Reassign] [Pause] [Cancel]
  - Mobile: single column, full width; Desktop: 2-col with sidebar for metadata
  - Accept: Figma mobile + desktop frames; live Phoenix page

- [ ] **D-2.2b** Status transition UI
  - Tap status badge to open a modal/dropdown with available transitions
  - Each status is a tappable button
  - Current status is highlighted
  - Accept: Modal mockup showing Triage → [Backlog / Canceled]

- [ ] **D-2.2c** Comment thread design
  - Each comment: avatar + author name + timestamp + text
  - Avatar: initials in colored circle (color per worker/role)
  - Reply button at end of detail page opens a form
  - Form: textarea + [Submit] [Cancel] buttons
  - Accept: Comment thread mockup + form spec

## Navigation & Layout (Phase 1–2)

### 3.1 — Mobile Bottom Tab Bar

**Current state:** App layouts in place; tab bar not yet designed.

**Design tasks:**
- [ ] **D-3.1a** Design the bottom navigation bar
  - Tabs: [Plans] [Active] [Chat] [Memory]
  - Icon + label per tab (label may hide on very narrow screens)
  - Active tab: primary color (Tracy cyan)
  - Inactive: neutral gray
  - Height: 64px (touch-friendly)
  - Fixed position at bottom on mobile; converts to left sidebar on desktop
  - Accept: Mobile mockup (375px) showing all 4 tabs

- [ ] **D-3.1b** Desktop sidebar navigation
  - Vertical layout of the same 4 tabs
  - Left sidebar, 200–240px wide
  - Collapsible on smallest screens (hamburger)
  - Accept: Desktop mockup (1920px) with sidebar

### 3.2 — Master/Detail Navigation

**Design tasks:**
- [ ] **D-3.2a** Drill-down pattern (mobile)
  - List view → tap card → detail page with [← back] button
  - Back button returns to list, preserves scroll position
  - No nested drilling (detail → detail not needed in Phase 1)
  - Accept: Flow diagram + 2-screen mockup

- [ ] **D-3.2b** Dual-pane pattern (desktop)
  - Optional: list on left, detail on right (side-by-side on large screens)
  - Or: full-width list, clicking a card opens a slide-out panel on the right
  - Decide based on real content width
  - Accept: Desktop layout mockup + interaction spec

## Cost Meter & Budget UI (Phase 1)

### 4.1 — Cost Meter Master Control

**Current state:** Placeholder meters on boardroom.html.heex (color-bar style per decision §3 in TRACY_PLAN_SURFACE.md).

**Design tasks:**
- [ ] **D-4.1a** Design the cost meter bar
  - Two meters: "SDK pool" (0–100 spent of 100 budget) + "Weekly" (0–100% of quota)
  - Stacked on narrow screens, side-by-side on desktop
  - Bar style: filled portion in color, empty in light gray
  - Colors: green (0–50%), yellow (50–75%), red (75–100%)
  - Label + percentage text above or overlaid
  - Hover/tap: tooltip showing exact amounts (e.g., "$47.32 / $100.00")
  - Accept: Figma frame showing 0%, 50%, 75%, 100% states; live component

- [ ] **D-4.1b** Cost meter placement & pinning
  - Pinned at top of page (under main header)
  - Always visible when scrolling
  - On mobile: 2-column layout (SDK / Weekly side-by-side)
  - On desktop: flex row, left-aligned or centered
  - Accept: Layout spec + live screenshot

## Auth & Settings (Phase 1)

### 5.1 — Login / Signup / Confirmation Pages

**Current state:** Phoenix phx.gen.auth templates exist (user_session, user_registration, user_settings); need design polish.

**Design tasks:**
- [ ] **D-5.1a** Login page
  - Hero section (left, desktop) or top (mobile): Tracy branding + tagline
  - Form section (right/bottom): email + password fields + [Log in] button
  - "Forgot password?" link (if implementing recovery)
  - "Sign up" link to registration
  - Centered on narrow screens, two-column on desktop
  - Accept: Mobile + desktop mockup

- [ ] **D-5.1b** Signup page
  - Similar layout to login
  - Fields: email + password + password confirmation
  - Validation messaging (real-time or on blur)
  - "[Log in instead]" link
  - Accept: Mobile + desktop mockup

- [ ] **D-5.1c** Email confirmation flow
  - Message: "Check your email to confirm your account"
  - Card-style layout with icon + instructions
  - Retry button if user didn't receive email
  - Accept: Mockup

- [ ] **D-5.1d** Settings page
  - User info section: email, password change
  - Theme toggle: [Dark] [Light] buttons or radio group
  - Session list (other login locations)
  - Logout button
  - Accept: Mobile + desktop mockup

## Icon System (Phase 1)

### 6.1 — Icon Library Specification

**Current state:** Using Heroicons (`hero-` prefix in components); solid style 20px.

**Design tasks:**
- [ ] **D-6.1a** Document the icon set in use
  - Confirm we're using Heroicons 24 (or the version bundled in `vendor/heroicons`)
  - Curate the subset used: document which icons map to which UI concepts
    - Status: check-circle, x-circle, exclamation-triangle, etc.
    - Actions: play, pause, trash, edit, etc.
    - Navigation: list, chart-bar, chat-bubble, etc.
  - All icons should be 20px or 24px size, solid style
  - Accept: Icon mapping spreadsheet + visual inventory page

- [ ] **D-6.1b** Custom icons (if needed)
  - If Heroicons doesn't have something specific, design custom SVGs
  - Style: match Heroicons (2px stroke, consistent cap/join)
  - Examples: Tracy logo, worker roles (Engineer, Researcher, Reviewer), etc.
  - Accept: SVG files in `assets/svgs/` + integrated into app

## Micro-interactions & Polish (Phase 2)

### 7.1 — Transitions & Animations

**Design tasks:**
- [ ] **D-7.1a** Define transition timings
  - Page transitions: 200–300ms fade
  - Hover effects: 100ms ease-out
  - Loading states: subtle spinner or skeleton pulse (300ms loop)
  - Status changes: toast notification slides in from top (300ms)
  - Accept: Transition specification doc + examples in Figma

- [ ] **D-7.1b** Interactive states
  - Button hover: slight brightness increase or box shadow
  - Button active/pressed: brightness decrease
  - Form inputs: focus ring (2px solid primary color)
  - Cards: hover adds subtle shadow or border highlight
  - Accept: Figma component states (default, hover, active, disabled, loading)

### 7.2 — Feedback & Validation

**Design tasks:**
- [ ] **D-7.2a** Form validation messaging
  - Inline error messages below field (red text, small font)
  - Success checkmark when field is valid
  - Required field indicator (red asterisk or "required" label)
  - Accept: Form mockup with 3 states (empty, error, valid)

- [ ] **D-7.2b** Toast notifications
  - Small card that appears at bottom-right (desktop) or bottom-center (mobile)
  - Success (green), warning (yellow), error (red) variants
  - Auto-dismiss after 5 seconds or tappable close button
  - Multiple toasts stack vertically
  - Accept: 3-variant mockup + spec

## Responsive Design & Mobile (Phase 1–2)

### 8.1 — Breakpoints & Grid

**Design tasks:**
- [ ] **D-8.1a** Responsive grid specification
  - Mobile (375–480px): single column, full width
  - Tablet (481–768px): 2 columns where applicable
  - Desktop (769px+): 3 columns for panels, sidebar nav
  - Gutters: 12px (mobile), 16px (tablet), 24px (desktop)
  - Accept: Breakpoint doc + grid mockups

- [ ] **D-8.1b** Touch-friendly sizing
  - Minimum touch target: 44×44px (buttons, tabs, interactive elements)
  - Spacing between touch targets: 8px minimum
  - List item height: 56px+ (comfortable tap)
  - Accept: Specification doc with measurements

## Dark / Light Theme Implementation (Phase 1)

### 9.1 — Theme Testing & Compliance

**Design tasks:**
- [ ] **D-9.1a** Test both themes for WCAG AA compliance
  - All text ≥ 14px should have ≥ 4.5:1 contrast
  - UI elements should have ≥ 3:1 contrast
  - Run app in both `data-theme="tracy"` and `data-theme="tracy-light"`
  - Use online contrast checker (WebAIM, Contrast Ratio)
  - Flag any violations and propose fixes to app.css
  - Accept: Contrast matrix (colors × foreground colors) showing all ratios ≥ required minimums

- [ ] **D-9.1b** Visual regression testing
  - Screenshot the app in both themes (boardroom page + detail page once live)
  - Compare side-by-side to ensure consistency
  - Ensure text is readable, contrast is comfortable
  - Accept: Side-by-side screenshot gallery

## Accessibility Audit (Phase 2)

### 10.1 — WCAG AA Compliance

**Design tasks:**
- [ ] **D-10.1a** Keyboard navigation spec
  - All interactive elements must be reachable via Tab key
  - Tab order must be logical (left-to-right, top-to-bottom)
  - Enter/Space activates buttons
  - Arrow keys navigate within focused components (e.g., tab bar, status dropdown)
  - Accept: Navigation diagram + test results

- [ ] **D-10.1b** Screen reader compatibility
  - All icons must have alt text or aria-label
  - Form fields must have associated labels
  - Landmark regions: `<main>`, `<nav>`, `<header>`, `<footer>`
  - Headings follow a logical hierarchy (h1 → h2 → h3, no skips)
  - Status changes announced via `aria-live`
  - Accept: Aria specification doc + tested with a screen reader (NVDA, VoiceOver)

## Design Deliverables Summary

| Task | Owner | Phase | Due | Deliverable |
|------|-------|-------|-----|-------------|
| D-1.1a | Designer | 1 | Week 1 | Design tokens doc + Figma color frame |
| D-1.1b | Designer | 1 | Week 1 | Signed-off palette |
| D-1.2a | Designer | 1 | Week 1 | Font decision + tailwind.config.ts update |
| D-1.2b | Designer | 1 | Week 1 | Type scale specimen page |
| D-1.3a | Designer | 1 | Week 2 | Component library Figma + live demo |
| D-1.3b | Designer | 1 | Week 2 | Empty state + loading state specs |
| D-2.1a | Designer | 2 | Week 1 | Plan list view Figma + Phoenix prototype |
| D-2.1b | Designer | 2 | Week 1 | Status header spec |
| D-2.1c | Designer | 2 | Week 1 | Cost visualization spec |
| D-2.2a | Designer | 2 | Week 2 | Detail page Figma + Phoenix page |
| D-2.2b | Designer | 2 | Week 2 | Status transition modal spec |
| D-2.2c | Designer | 2 | Week 2 | Comment thread design |
| D-3.1a | Designer | 2 | Week 1 | Mobile tab bar mockup |
| D-3.1b | Designer | 2 | Week 1 | Desktop sidebar mockup |
| D-3.2a | Designer | 2 | Week 2 | Mobile drill-down flow |
| D-3.2b | Designer | 2 | Week 2 | Desktop layout pattern |
| D-4.1a | Designer | 1 | Week 2 | Cost meter Figma + live component |
| D-4.1b | Designer | 1 | Week 2 | Placement & pinning spec |
| D-5.1a–d | Designer | 1 | Week 2 | Auth page mockups (4 pages) |
| D-6.1a | Designer | 1 | Week 2 | Icon mapping doc |
| D-6.1b | Designer | 1 | Week 2 | Custom SVGs (if needed) |
| D-7.1a | Designer | 2 | Week 2 | Transition spec + examples |
| D-7.1b | Designer | 2 | Week 2 | Interactive states Figma |
| D-7.2a | Designer | 2 | Week 2 | Form validation design |
| D-7.2b | Designer | 2 | Week 2 | Toast notification spec |
| D-8.1a | Designer | 1 | Week 2 | Responsive grid spec |
| D-8.1b | Designer | 1 | Week 2 | Touch-friendly sizing spec |
| D-9.1a | Designer | 1 | Week 2 | Contrast matrix |
| D-9.1b | Designer | 2 | Week 1 | Screenshot regression report |
| D-10.1a | Designer | 2 | Week 2 | Keyboard navigation spec |
| D-10.1b | Designer | 2 | Week 2 | Aria specification doc |

## Success Criteria

- [ ] Figma design file covers all major screens (list, detail, auth, settings)
- [ ] Live Phoenix components match Figma designs within 5% pixel tolerance
- [ ] Both themes (tracy dark + tracy-light) pass WCAG AA contrast
- [ ] All interactive elements are reachable via keyboard
- [ ] Touch targets are ≥ 44×44px with 8px minimum spacing
- [ ] Component library is documented and reusable
- [ ] Design handoff includes:
  - Figma link with all components
  - Design tokens spreadsheet (colors, typography, spacing)
  - Interaction spec (transitions, states, micro-interactions)
  - Responsive design breakpoints
  - Accessibility checklist (WCAG AA)

## Notes for Designer

1. **Spidey-inspired vibe:** The color palette is intentionally inspired by Tyler the Creator + Spider-Man (cyan, red, blue). Lean into that energy in component style, but keep the UI professional and readable.

2. **Mobile-first constraint:** Assume a 375px phone viewport. Design for that first, then enhance for tablet and desktop. No horizontal scrolling.

3. **Lean component library:** daisyUI provides semantic defaults (btn-primary, alert-error, etc.). We're not reinventing components — we're customizing them via Tailwind + theme tokens.

4. **Tech constraints:**
   - All designs must be buildable in Phoenix + LiveView (no JavaScript-heavy interactions)
   - Use Tailwind CSS for styling (no CSS-in-JS or manual CSS)
   - Heroicons for icons (bundled in vendor/)
   - daisyUI for semantic component theming

5. **Iterate with the engineer:** Once you start designing the list view (D-2.1a), sync with the engineer building the LiveView component so LiveView events (collapse, drill-down, status change) map to your interactions.

6. **Reference**: Read `TRACY_PLAN_SURFACE.md` for the full UI philosophy and examples.

---

**Questions or blockers?** Flag in the Tracy boardroom chat.

/**
 * ScrollRestore — preserves scroll position across LiveView push_patch navigation.
 *
 * Mount on the scrollable list container:
 *
 *   <div id="list-screen"
 *        phx-hook="ScrollRestore"
 *        data-scroll-key="plan-list"
 *        class="screen screen-list">
 *
 * On every scroll event the current scrollTop is stored in sessionStorage.
 * When the LiveView remounts (e.g. navigating back from detail to list) the
 * saved position is restored before the first paint, then cleared so a fresh
 * visit starts at the top.
 *
 * Spec: workspaces/plans/.../master-detail/master-detail-spec.md §A
 */
export const ScrollRestore = {
  mounted() {
    const key = `scroll:${this.el.dataset.scrollKey}`
    const saved = sessionStorage.getItem(key)
    if (saved) {
      requestAnimationFrame(() => {
        this.el.scrollTop = parseInt(saved, 10)
        sessionStorage.removeItem(key)
      })
    }
    this.el.addEventListener(
      "scroll",
      () => { sessionStorage.setItem(key, this.el.scrollTop) },
      { passive: true }
    )
  }
}

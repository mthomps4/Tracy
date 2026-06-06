// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tracy"
import topbar from "../vendor/topbar"

// ---- Master/detail navigation hooks -------------------------------------
import {ScrollRestore} from "./hooks/scroll_restore"
import {DetailFade} from "./hooks/detail_fade"

// ---- Loading hooks -------------------------------------------------------
//
// PageLoading — full-viewport overlay during initial session bootstrap.
// Mount on: <div id="page-loading" class="page-loading" phx-hook="PageLoading">
//
// Shows after a 300 ms delay (prevents flash on fast connections).
// Remove the element from the DOM (or set hidden) to dismiss.
const PageLoading = {
  mounted() {
    this._timer = setTimeout(() => this.el.classList.add("visible"), 300)
  },
  destroyed() {
    clearTimeout(this._timer)
  }
}

// ---- Boardroom hooks -----------------------------------------------------
const ScrollToBottom = {
  mounted() {
    this.scroll()
    this.observer = new MutationObserver(() => this.scroll())
    this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
  },
  updated() { this.scroll() },
  destroyed() { this.observer && this.observer.disconnect() },
  scroll() { this.el.scrollTop = this.el.scrollHeight }
}

const GrowComposer = {
  mounted() {
    this.grow()
    this.el.addEventListener("input", () => this.grow())
  },
  grow() {
    this.el.style.height = "auto"
    const cap = 6 * parseFloat(getComputedStyle(this.el).lineHeight || "24")
    this.el.style.height = Math.min(this.el.scrollHeight, cap) + "px"
  }
}

// Submit the composer on plain Enter (Shift+Enter inserts newline).
window.addEventListener("tracy:submit-on-enter", (e) => {
  if (e.detail && e.detail.shiftKey) return
  const form = e.target && e.target.closest("form")
  if (form) {
    e.preventDefault && e.preventDefault()
    form.requestSubmit && form.requestSubmit()
  }
})

// ---- ChatDock — sticky JARVIS-style chat surface ------------------------
//
// Global keybindings, focus management, bottom-sheet drag (mobile),
// click-outside-to-close. Mounts on the chat-dock-root container.
const ChatDock = {
  mounted() {
    this._onKey = (e) => {
      // Cmd+J / Ctrl+J — toggle open
      if ((e.metaKey || e.ctrlKey) && (e.key === "j" || e.key === "J")) {
        e.preventDefault()
        this.pushEvent("toggle")
        // After server flips open, focus the input
        setTimeout(() => {
          const ta = document.getElementById("chat-dock-input")
          ta && ta.focus()
        }, 30)
        return
      }
      // Esc — close when open
      if (e.key === "Escape" && this.el.dataset.open === "true") {
        e.preventDefault()
        this.pushEvent("close")
      }
    }
    document.addEventListener("keydown", this._onKey)

    this._onClickOutside = (e) => {
      if (this.el.dataset.open !== "true") return
      if (this.el.contains(e.target)) return
      // Don't close while focused on textarea (mobile keyboard pop)
      const active = document.activeElement
      if (active && this.el.contains(active)) return
      this.pushEvent("close")
    }
    document.addEventListener("pointerdown", this._onClickOutside)

    // Bottom-sheet drag (mobile) — drag the header handle to snap between
    // peek / half / full.
    this._setupDrag()
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKey)
    document.removeEventListener("pointerdown", this._onClickOutside)
  },

  _setupDrag() {
    const header = this.el.querySelector(".chat-dock__header")
    if (!header) {
      // header doesn't exist until open — listen for first appearance
      this._mo = new MutationObserver(() => this._setupDrag())
      this._mo.observe(this.el, {childList: true, subtree: true})
      return
    }
    this._mo && this._mo.disconnect()
    let startY = null
    let startSnap = this.el.dataset.snap
    header.addEventListener("touchstart", (e) => {
      startY = e.touches[0].clientY
      startSnap = this.el.dataset.snap
    }, {passive: true})
    header.addEventListener("touchmove", (e) => {
      if (startY == null) return
      const dy = e.touches[0].clientY - startY
      // Visual: just rely on snap states for now; advanced drag-resize later.
      if (Math.abs(dy) > 50) {
        const target = dy > 0
          ? (startSnap === "full" ? "half" : "peek")
          : (startSnap === "peek" ? "half" : "full")
        if (target !== startSnap) {
          this.pushEvent("snap", {to: target})
          startSnap = target
          startY = e.touches[0].clientY
        }
      }
    }, {passive: true})
    header.addEventListener("touchend", () => { startY = null }, {passive: true})
  }
}

// ---- VoiceInput — browser SpeechRecognition wrapper ---------------------
//
// Tap the mic button → start listening. Interim transcripts stream into
// the composer; final result pushes voice:transcript with final=true,
// which the LiveView auto-submits.
//
// Browser support: Chrome / Safari (with webkit prefix) / Edge. Falls
// back gracefully on Firefox with an alert.
const VoiceInput = {
  mounted() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) {
      this.el.classList.add("chat-dock__mic--unsupported")
      this.el.title = "Voice input unsupported in this browser — try Safari or Chrome"
      this.el.addEventListener("click", () => {
        alert("Voice input needs SpeechRecognition API — try Safari (iOS/macOS), Chrome, or Edge.")
      })
      return
    }

    this._rec = new SR()
    this._rec.continuous = false
    this._rec.interimResults = true
    this._rec.lang = "en-US"

    this._rec.onresult = (evt) => {
      let text = ""
      let isFinal = false
      for (let i = evt.resultIndex; i < evt.results.length; i++) {
        text += evt.results[i][0].transcript
        if (evt.results[i].isFinal) isFinal = true
      }
      this.pushEventTo("#chat-dock-root", "voice:transcript", {text, final: isFinal})
    }

    this._rec.onstart = () => {
      this.pushEventTo("#chat-dock-root", "voice:start", {})
    }

    this._rec.onend = () => {
      this.pushEventTo("#chat-dock-root", "voice:stop", {})
    }

    this._rec.onerror = (evt) => {
      console.warn("SpeechRecognition error:", evt.error)
      this.pushEventTo("#chat-dock-root", "voice:stop", {})
    }

    this.el.addEventListener("click", () => {
      const listening = this.el.dataset.listening === "true"
      try {
        if (listening) {
          this._rec.stop()
        } else {
          this._rec.start()
        }
      } catch (err) {
        console.warn("voice toggle:", err)
      }
    })
  },

  destroyed() {
    if (this._rec) {
      try { this._rec.stop() } catch (_) {}
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PageLoading, ScrollToBottom, GrowComposer, ScrollRestore, DetailFade, ChatDock, VoiceInput},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


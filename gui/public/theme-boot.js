// Applies the saved theme before the first paint, so the page never flashes the
// wrong theme. The server's settings are applied again once the session loads.
(function applySavedTheme() {
  try {
    var theme = window.localStorage.getItem("backup-suite-gui-theme");
    if (theme === "light" || theme === "dark") document.documentElement.setAttribute("data-theme", theme);
  } catch (error) {
    // Storage unavailable: follow the system theme.
  }
})();

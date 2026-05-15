(function () {
  const popoverMenuSelector = "details[data-popover-menu]";

  function summaryFor(menu) {
    return menu.querySelector("summary");
  }

  function setExpanded(menu) {
    const summary = summaryFor(menu);
    if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
  }

  function closestPopoverMenu(target) {
    return target instanceof Element ? target.closest(popoverMenuSelector) : null;
  }

  function closePopoverMenus(except) {
    document.querySelectorAll(popoverMenuSelector + "[open]").forEach(function (menu) {
      if (menu !== except) {
        menu.open = false;
        setExpanded(menu);
      }
    });
  }

  function initPopoverMenus() {
    document.querySelectorAll(popoverMenuSelector).forEach(function (menu) {
      if (menu.dataset.popoverMenuReady === "yes") return;
      menu.dataset.popoverMenuReady = "yes";
      setExpanded(menu);
      menu.addEventListener("toggle", function () {
        setExpanded(menu);
        if (menu.open) closePopoverMenus(menu);
      });
    });

    if (document.body.dataset.popoverMenusReady === "yes") return;
    document.body.dataset.popoverMenusReady = "yes";

    document.addEventListener("pointerdown", function (event) {
      closePopoverMenus(closestPopoverMenu(event.target));
    }, true);

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;

      const openMenu = document.querySelector(popoverMenuSelector + "[open]");
      if (!openMenu) return;

      const activeMenu = closestPopoverMenu(event.target);
      closePopoverMenus(null);
      if (activeMenu) {
        const summary = summaryFor(activeMenu);
        if (summary) summary.focus();
      }
      event.preventDefault();
      event.stopPropagation();
    }, true);
  }

  function setNavBadge(link, value) {
    let badge = link.querySelector(".nav-badge");
    if (value > 0) {
      if (!badge) {
        badge = document.createElement("span");
        badge.className = "nav-badge";
        link.appendChild(badge);
      }
      badge.textContent = String(value);
    } else if (badge) {
      badge.remove();
    }
  }

  function updateNavStats(stats) {
    ["issues", "pulls"].forEach(function (key) {
      const value = Number(stats && stats[key]);
      if (!Number.isFinite(value)) return;
      document.querySelectorAll('[data-nav-count="' + key + '"]').forEach(function (link) {
        setNavBadge(link, value);
      });
    });
  }

  function initNavStats() {
    if (!window.fetch || document.body.dataset.navStatsReady === "yes") return;
    if (!document.querySelector("[data-nav-count]")) return;
    document.body.dataset.navStatsReady = "yes";

    fetch("/nav/stats", { cache: "no-store" })
      .then(function (response) {
        return response.ok ? response.json() : null;
      })
      .then(function (stats) {
        if (stats) updateNavStats(stats);
      })
      .catch(function () {});
  }

  function initUi() {
    initPopoverMenus();
    initNavStats();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initUi);
  } else {
    initUi();
  }
}());

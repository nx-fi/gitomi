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

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initPopoverMenus);
  } else {
    initPopoverMenus();
  }
}());

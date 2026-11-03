const API_URL = "https://us-central1-vemuni-d4f87.cloudfunctions.net/getSharedMenu";
const PICKS_API_URL = "https://us-central1-vemuni-d4f87.cloudfunctions.net/updateTablePicks";
const params = new URLSearchParams(window.location.search);
const shareID = params.get("id") || "";
const picksKey = `vemuni.sharedMenu.${shareID}.picks`;
const participantKey = `vemuni.sharedMenu.${shareID}.participant`;
const displayNameKey = `vemuni.sharedMenu.${shareID}.displayName`;
let menu = null;
let tablePicks = [];
let participantCount = 0;
let displayName = localStorage.getItem(displayNameKey) || "";
let pendingPickKey = null;
let activeFilter = "all";
let query = "";
let picksSyncGeneration = 0;
let picks = new Set(JSON.parse(localStorage.getItem(picksKey) || "[]"));
let participantID = localStorage.getItem(participantKey) || createParticipantID();
localStorage.setItem(participantKey, participantID);

const loading = document.querySelector("#loading");
const errorPanel = document.querySelector("#error");
const menuApp = document.querySelector("#menu-app");
const sectionsNode = document.querySelector("#menu-sections");
const emptyNode = document.querySelector("#empty-results");
const nameDialog = document.querySelector("#name-dialog");
const nameInput = document.querySelector("#display-name");

async function loadMenu() {
  if (!/^[A-Za-z0-9_-]{12}$/.test(shareID)) return showError("This menu link is invalid.");
  try {
    const response = await fetch(`${API_URL}?id=${encodeURIComponent(shareID)}`, { headers: { Accept: "application/json" } });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || "This shared menu could not be opened.");
    menu = payload.menu;
    tablePicks = Array.isArray(payload.tablePicks) ? payload.tablePicks : [];
    participantCount = Number(payload.participantCount || 0);
    document.title = `${menu.restaurantName || "Shared Menu"} — Vemuni`;
    document.querySelector("#restaurant-name").textContent = menu.restaurantName || "Restaurant Menu";
    loading.hidden = true;
    menuApp.hidden = false;
    bindControls();
    render();
    if (picks.size) syncTablePicks();
    window.setInterval(refreshTablePicks, 5000);
  } catch (error) {
    showError(error.message);
  }
}

function showError(message) {
  loading.hidden = true;
  menuApp.hidden = true;
  errorPanel.hidden = false;
  document.querySelector("#error-message").textContent = message;
}

function bindControls() {
  updateDisplayNameButton();
  document.querySelector("#display-name-button").addEventListener("click", openNameDialog);
  document.querySelector("#name-cancel").addEventListener("click", () => {
    pendingPickKey = null;
    nameDialog.close();
  });
  document.querySelector("#name-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const value = cleanDisplayName(nameInput.value);
    if (!value) return;
    displayName = value;
    localStorage.setItem(displayNameKey, displayName);
    updateDisplayNameButton();
    nameDialog.close();
    if (pendingPickKey) {
      const key = pendingPickKey;
      pendingPickKey = null;
      togglePick(key);
    } else if (picks.size) {
      syncTablePicks();
    }
  });
  document.querySelector("#menu-search").addEventListener("input", (event) => {
    query = normalize(event.target.value);
    render();
  });
  document.querySelector("#filter-chips").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-filter]");
    if (!button) return;
    activeFilter = button.dataset.filter;
    document.querySelectorAll(".shared-chip").forEach((chip) => chip.classList.toggle("active", chip === button));
    render();
  });
}

function render() {
  sectionsNode.replaceChildren();
  let visibleCount = 0;
  menu.menuSections.forEach((section, sectionIndex) => {
    const visibleItems = section.items
      .map((item, itemIndex) => ({ item, itemIndex }))
      .filter(({ item }) => matches(item, section.name));
    if (!visibleItems.length) return;
    visibleCount += visibleItems.length;

    const sectionNode = document.createElement("section");
    sectionNode.className = "shared-menu-section";
    const heading = document.createElement("h2");
    heading.textContent = section.name;
    sectionNode.append(heading);

    visibleItems.forEach(({ item, itemIndex }) => {
      const key = itemKey(sectionIndex, itemIndex, item);
      sectionNode.append(menuCard(item, key));
    });
    sectionsNode.append(sectionNode);
  });
  emptyNode.hidden = visibleCount !== 0;
  updatePicksSummary();
}

function menuCard(item, key) {
  const options = pickOptions(item, key);
  const article = document.createElement("article");
  article.className = `shared-menu-card${options.some((option) => picks.has(option.key)) || picks.has(key) ? " selected" : ""}`;

  const top = document.createElement("div");
  top.className = "shared-item-top";
  const titleWrap = document.createElement("div");
  const title = document.createElement("h3");
  title.textContent = item.originalName;
  titleWrap.append(title);
  if (item.englishName && normalize(item.englishName) !== normalize(item.originalName)) {
    const translation = document.createElement("p");
    translation.className = "shared-translation";
    translation.textContent = item.englishName;
    titleWrap.append(translation);
  }
  top.append(titleWrap);
  const displayedPrice = optionalText(item.price);
  if (displayedPrice) {
    const price = document.createElement("strong");
    price.className = "shared-price";
    price.textContent = displayedPrice;
    top.append(price);
  }
  article.append(top);

  if (item.explanation) {
    const explanation = document.createElement("p");
    explanation.className = "shared-explanation";
    explanation.textContent = item.explanation;
    article.append(explanation);
  }

  const details = detailTags(item);
  if (details.length) {
    const tags = document.createElement("div");
    tags.className = "shared-tags";
    details.forEach((value) => {
      const tag = document.createElement("span");
      tag.textContent = value;
      tags.append(tag);
    });
    article.append(tags);
  }

  const pickActions = document.createElement("div");
  pickActions.className = "shared-pick-options";
  options.forEach((option) => {
    const pickButton = document.createElement("button");
    const selected = picks.has(option.key);
    pickButton.type = "button";
    pickButton.className = "shared-pick-button";
    pickButton.textContent = pickButtonText(option, selected);
    pickButton.addEventListener("click", () => {
      if (!selected && !displayName) {
        pendingPickKey = option.key;
        openNameDialog();
        return;
      }
      togglePick(option.key);
    });
    pickActions.append(pickButton);
  });
  article.append(pickActions);
  return article;
}

function detailTags(item) {
  if (item.wineDetails) {
    const wine = item.wineDetails;
    return [wine.grape, wine.region, wine.vintage, ...(wine.flavors || []), ...(wine.foodPairings || []).map((value) => `Pairs with ${value}`)].filter(Boolean).slice(0, 7);
  }
  if (item.drinkDetails) return [...(item.drinkDetails.flavorProfile || []), item.drinkDetails.baseSpirit].filter(Boolean).slice(0, 5);
  return [...(item.dietary || []), ...(item.allergens || []).map((value) => `Contains ${value}`)].slice(0, 5);
}

function matches(item, sectionName) {
  const type = item.itemType || "unknown";
  const section = normalize(sectionName);
  const filterMatch = activeFilter === "all"
    || (activeFilter === "food" && type === "food" && !section.includes("dessert"))
    || (activeFilter === "drink" && type === "drink")
    || (activeFilter === "wine" && type === "wine")
    || (activeFilter === "dessert" && (section.includes("dessert") || section.includes("sweet")));
  if (!filterMatch) return false;
  if (!query) return true;
  const wine = item.wineDetails || {};
  const drink = item.drinkDetails || {};
  const text = normalize([
    sectionName, item.originalName, item.englishName, item.explanation, item.price,
    ...(item.dietary || []), ...(item.allergens || []), wine.grape, wine.region,
    ...(wine.flavors || []), ...(wine.foodPairings || []), drink.baseSpirit,
    ...(drink.ingredients || []), ...(drink.flavorProfile || [])
  ].filter(Boolean).join(" "));
  return query.split(/\s+/).every((term) => text.includes(term));
}

function updatePicksSummary() {
  document.querySelector("#pick-count").textContent = `${picks.size} ${picks.size === 1 ? "item" : "items"}`;
  const pickedItems = [];
  const selectedPrices = [];
  menu.menuSections.forEach((section, sectionIndex) => section.items.forEach((item, itemIndex) => {
    const key = itemKey(sectionIndex, itemIndex, item);
    const options = pickOptions(item, key);
    options.forEach((option) => {
      if (!picks.has(option.key)) return;
      pickedItems.push({ key: option.key, item, option });
      const match = String(option.price || "").match(/^\s*\$?(\d+(?:\.\d{1,2})?)\s*$/);
      if (match) selectedPrices.push(Number(match[1]));
    });

    // A shared menu created before serving choices existed may still contain a base pick.
    if (options.every((option) => option.key !== key) && picks.has(key)) {
      pickedItems.push({ key, item, option: { label: "", price: item.price } });
      const match = String(item.price || "").match(/^\s*\$?(\d+(?:\.\d{1,2})?)\s*$/);
      if (match) selectedPrices.push(Number(match[1]));
    }
  }));
  const total = selectedPrices.reduce((sum, value) => sum + value, 0);
  document.querySelector("#pick-total").textContent = selectedPrices.length === picks.size && picks.size ? `Estimated ${formatCurrency(total)}` : "";

  const picksList = document.querySelector("#picks-list");
  picksList.replaceChildren();
  pickedItems.forEach(({ key, item, option }) => {
    const row = document.createElement("div");
    row.className = "shared-picked-item";

    const name = document.createElement("span");
    name.className = "shared-picked-name";
    name.textContent = option.label ? `${item.originalName} · ${option.label}` : item.originalName;
    row.append(name);

    const displayedPrice = optionalText(option.price);
    if (displayedPrice) {
      const price = document.createElement("span");
      price.className = "shared-picked-price";
      price.textContent = displayedPrice;
      row.append(price);
    }

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "shared-picked-remove";
    remove.textContent = "Remove";
    remove.setAttribute("aria-label", `Remove ${item.originalName}${option.label ? ` ${option.label}` : ""} from My Picks`);
    remove.addEventListener("click", () => {
      picks.delete(key);
      localStorage.setItem(picksKey, JSON.stringify([...picks]));
      render();
      syncTablePicks();
    });
    row.append(remove);
    picksList.append(row);
  });
  picksList.hidden = pickedItems.length === 0;
  renderTablePicks();
}

function renderTablePicks() {
  const panel = document.querySelector("#table-picks-panel");
  const list = document.querySelector("#table-picks-list");
  document.querySelector("#table-people-count").textContent = `· ${participantCount} ${participantCount === 1 ? "person" : "people"}`;
  list.replaceChildren();
  tablePicks.forEach((pick) => {
    const row = document.createElement("div");
    row.className = "shared-table-pick";
    const copy = document.createElement("span");
    copy.className = "shared-table-pick-copy";
    const name = document.createElement("span");
    name.textContent = pick.name;
    const names = document.createElement("span");
    names.className = "shared-table-names";
    names.textContent = Array.isArray(pick.pickedBy) ? pick.pickedBy.join(" · ") : "";
    copy.append(name, names);
    const count = document.createElement("span");
    count.textContent = `${pick.count} ${pick.count === 1 ? "pick" : "picks"}`;
    row.append(copy, count);
    list.append(row);
  });
  panel.hidden = tablePicks.length === 0;
}

async function syncTablePicks() {
  const generation = ++picksSyncGeneration;
  try {
    const response = await fetch(PICKS_API_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ id: shareID, participantId: participantID, displayName, picks: [...picks] })
    });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || "Table Picks could not be updated.");
    if (generation !== picksSyncGeneration) return;
    tablePicks = Array.isArray(payload.tablePicks) ? payload.tablePicks : [];
    participantCount = Number(payload.participantCount || 0);
    renderTablePicks();
  } catch (error) {
    console.warn("Vemuni Table Picks sync failed", error);
  }
}

async function refreshTablePicks() {
  try {
    const response = await fetch(`${API_URL}?id=${encodeURIComponent(shareID)}&picksOnly=1`, {
      headers: { Accept: "application/json" },
      cache: "no-store"
    });
    const payload = await response.json();
    if (!response.ok) return;
    tablePicks = Array.isArray(payload.tablePicks) ? payload.tablePicks : [];
    participantCount = Number(payload.participantCount || 0);
    renderTablePicks();
  } catch {
    // Keep the last successful counts visible during a temporary connection issue.
  }
}

function formatCurrency(value) {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: menu.currencyCode || "USD", maximumFractionDigits: 2 }).format(value);
  } catch {
    return `$${value.toFixed(2)}`;
  }
}

function normalize(value) {
  return String(value || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function optionalText(value) {
  const text = String(value ?? "").trim();
  return /^(null|undefined|n\/?a|none)$/i.test(text) ? "" : text;
}

function itemKey(sectionIndex, itemIndex, item) {
  return `${sectionIndex}-${itemIndex}-${item.originalName}-${item.price || ""}`;
}

function pickOptions(item, baseKey) {
  const wine = item.wineDetails || {};
  const glassPrice = optionalText(wine.glassPrice);
  const bottlePrice = optionalText(wine.bottlePrice);
  const options = [];
  if (glassPrice) options.push({ key: `${baseKey}|serving:glass`, label: "Glass", symbol: "🍷", price: glassPrice });
  if (bottlePrice) options.push({ key: `${baseKey}|serving:bottle`, label: "Bottle", symbol: "🍾", price: bottlePrice });
  return options.length ? options : [{ key: baseKey, label: "", symbol: "", price: item.price }];
}

function pickButtonText(option, selected) {
  if (!option.label) return selected ? "✓ Added to My Picks" : "+ Add to My Picks";
  const action = selected ? "✓ Added" : "+ Add";
  return `${action} ${option.symbol} ${option.label}${option.price ? ` · ${option.price}` : ""}`;
}

function createParticipantID() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function togglePick(key) {
  picks.has(key) ? picks.delete(key) : picks.add(key);
  localStorage.setItem(picksKey, JSON.stringify([...picks]));
  render();
  syncTablePicks();
}

function openNameDialog() {
  nameInput.value = displayName;
  nameDialog.showModal();
  window.setTimeout(() => nameInput.focus(), 50);
}

function updateDisplayNameButton() {
  document.querySelector("#display-name-button").textContent = displayName
    ? `Picking as ${displayName} · Edit`
    : "Add your name to Table Picks";
}

function cleanDisplayName(value) {
  return String(value || "").replace(/[\u0000-\u001F\u007F]/g, "").replace(/\s+/g, " ").trim().slice(0, 30);
}

loadMenu();

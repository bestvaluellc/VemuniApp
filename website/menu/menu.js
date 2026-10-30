const API_URL = "https://us-central1-vemuni-d4f87.cloudfunctions.net/getSharedMenu";
const params = new URLSearchParams(window.location.search);
const shareID = params.get("id") || "";
const picksKey = `vemuni.sharedMenu.${shareID}.picks`;
let menu = null;
let activeFilter = "all";
let query = "";
let picks = new Set(JSON.parse(localStorage.getItem(picksKey) || "[]"));

const loading = document.querySelector("#loading");
const errorPanel = document.querySelector("#error");
const menuApp = document.querySelector("#menu-app");
const sectionsNode = document.querySelector("#menu-sections");
const emptyNode = document.querySelector("#empty-results");

async function loadMenu() {
  if (!/^[A-Za-z0-9_-]{12}$/.test(shareID)) return showError("This menu link is invalid.");
  try {
    const response = await fetch(`${API_URL}?id=${encodeURIComponent(shareID)}`, { headers: { Accept: "application/json" } });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || "This shared menu could not be opened.");
    menu = payload.menu;
    document.title = `${menu.restaurantName || "Shared Menu"} — Vemuni`;
    document.querySelector("#restaurant-name").textContent = menu.restaurantName || "Restaurant Menu";
    const expires = new Date(payload.expiresAt);
    document.querySelector("#expiry-note").textContent = `Available until ${expires.toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}`;
    loading.hidden = true;
    menuApp.hidden = false;
    bindControls();
    render();
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
      const key = `${sectionIndex}-${itemIndex}-${item.originalName}-${item.price || ""}`;
      sectionNode.append(menuCard(item, key));
    });
    sectionsNode.append(sectionNode);
  });
  emptyNode.hidden = visibleCount !== 0;
  updatePicksSummary();
}

function menuCard(item, key) {
  const article = document.createElement("article");
  article.className = `shared-menu-card${picks.has(key) ? " selected" : ""}`;

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
  if (item.price) {
    const price = document.createElement("strong");
    price.className = "shared-price";
    price.textContent = item.price;
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

  const pickButton = document.createElement("button");
  pickButton.type = "button";
  pickButton.className = "shared-pick-button";
  pickButton.textContent = picks.has(key) ? "✓ Added to My Picks" : "+ Add to My Picks";
  pickButton.addEventListener("click", () => {
    picks.has(key) ? picks.delete(key) : picks.add(key);
    localStorage.setItem(picksKey, JSON.stringify([...picks]));
    render();
  });
  article.append(pickButton);
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
  const selectedPrices = [];
  menu.menuSections.forEach((section, sectionIndex) => section.items.forEach((item, itemIndex) => {
    const key = `${sectionIndex}-${itemIndex}-${item.originalName}-${item.price || ""}`;
    if (!picks.has(key)) return;
    const match = String(item.price || "").match(/^\s*\$?(\d+(?:\.\d{1,2})?)\s*$/);
    if (match) selectedPrices.push(Number(match[1]));
  }));
  const total = selectedPrices.reduce((sum, value) => sum + value, 0);
  document.querySelector("#pick-total").textContent = selectedPrices.length === picks.size && picks.size ? `Estimated ${formatCurrency(total)}` : "";
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

loadMenu();

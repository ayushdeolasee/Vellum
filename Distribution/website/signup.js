const dialog = document.querySelector("#testflight-dialog");
const openButton = document.querySelector("#open-testflight-signup");
const closeButtons = dialog.querySelectorAll("[data-close-dialog]");
const form = dialog.querySelector("#testflight-form");
const submitButton = form.querySelector("button[type='submit']");
const status = form.querySelector("#signup-status");
const formFields = dialog.querySelector("#signup-fields");
const successMessage = dialog.querySelector("#signup-success");
let turnstileWidgetId = null;

function renderTurnstile() {
  if (!dialog.open || !window.turnstile || turnstileWidgetId !== null) return;

  turnstileWidgetId = window.turnstile.render("#testflight-turnstile", {
    sitekey: "0x4AAAAAAEclvD0VFvirViyR",
    action: "testflight-signup",
    theme: "light",
    size: window.innerWidth <= 380 ? "compact" : "normal",
    callback: () => {
      status.textContent = "";
    },
    "error-callback": () => {
      status.textContent = "The security check could not load. Refresh the page and try again.";
    },
    "expired-callback": () => {
      status.textContent = "The security check expired. Complete it again.";
    },
  });
}

window.onTurnstileReady = renderTurnstile;

openButton.addEventListener("click", () => {
  dialog.showModal();
  renderTurnstile();
  form.querySelector("#first-name").focus();
});

closeButtons.forEach((button) => {
  button.addEventListener("click", () => dialog.close());
});

dialog.addEventListener("click", (event) => {
  if (event.target === dialog) dialog.close();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  status.textContent = "";

  if (!form.reportValidity()) return;

  const data = new FormData(form);
  const turnstileToken = data.get("cf-turnstile-response");
  if (!turnstileToken) {
    status.textContent = "Complete the security check first.";
    return;
  }

  submitButton.disabled = true;
  submitButton.textContent = "Joining…";

  try {
    const response = await fetch("/api/testflight-signups", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        firstName: data.get("firstName"),
        lastName: data.get("lastName"),
        email: data.get("email"),
        website: data.get("website"),
        turnstileToken,
      }),
    });
    const result = await response.json();

    if (!response.ok) {
      throw new Error(result.error || "We could not save your signup. Try again in a moment.");
    }

    formFields.hidden = true;
    successMessage.hidden = false;
    successMessage.querySelector("h3").textContent = result.outcome === "already_registered"
      ? "You're already on the list."
      : "You're on the list.";
    successMessage.querySelector("button").focus();
  } catch (error) {
    status.textContent = error.message;
    if (window.turnstile && turnstileWidgetId !== null) window.turnstile.reset(turnstileWidgetId);
  } finally {
    submitButton.disabled = false;
    submitButton.textContent = "Join TestFlight";
  }
});

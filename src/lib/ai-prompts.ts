import toolDescriptionsMarkdown from "@/prompts/tool-descriptions.md?raw";
import toolModeSystemTemplateMarkdown from "@/prompts/tool-mode-system.md?raw";
import toolModeNativeTemplateMarkdown from "@/prompts/tool-mode-native.md?raw";

interface ToolModePromptParams {
  conversation: string;
  context: string;
  latestUserRequest: string;
}

function normalizeTemplate(template: string): string {
  return template.trim();
}

function renderTemplate(
  template: string,
  replacements: Record<string, string>,
): string {
  let rendered = template;
  for (const [key, value] of Object.entries(replacements)) {
    rendered = rendered.replaceAll(`{{${key}}}`, value);
  }
  return rendered.trim();
}

const TOOL_DESCRIPTIONS = normalizeTemplate(toolDescriptionsMarkdown);
const TOOL_MODE_SYSTEM_TEMPLATE = normalizeTemplate(
  toolModeSystemTemplateMarkdown,
).replace("{{TOOL_DESCRIPTIONS}}", TOOL_DESCRIPTIONS);
const TOOL_MODE_NATIVE_SYSTEM = normalizeTemplate(toolModeNativeTemplateMarkdown);

// Prompt for the JSON tool-calling path (providers without AI SDK native tool
// support, e.g. the Codex CLI). The model must return a strict JSON object.
export function buildToolModePrompt(params: ToolModePromptParams): string {
  return renderTemplate(TOOL_MODE_SYSTEM_TEMPLATE, {
    CONVERSATION: params.conversation,
    CONTEXT: params.context,
    LATEST_USER_REQUEST: params.latestUserRequest,
  });
}

// System prompt for the AI SDK native tool-calling path. Tool schemas and
// descriptions are supplied to the model through the SDK's tool definitions, so
// this only carries the role, policy, and response guidance.
export function buildNativeToolSystemPrompt(): string {
  return TOOL_MODE_NATIVE_SYSTEM;
}

// User message for the native tool-calling path: conversation, document context,
// and the latest request. (The JSON path bakes these into a single prompt via
// buildToolModePrompt instead.)
export function buildNativeToolUserPrompt(params: ToolModePromptParams): string {
  return [
    "### Recent Conversation",
    params.conversation,
    "",
    "### Document Context",
    params.context,
    "",
    "### Latest User Request",
    params.latestUserRequest,
  ].join("\n");
}

import toolDescriptionsMarkdown from "@/prompts/tool-descriptions.md?raw";
import toolModeSystemTemplateMarkdown from "@/prompts/tool-mode-system.md?raw";

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

export function buildToolModePrompt(params: ToolModePromptParams): string {
  return renderTemplate(TOOL_MODE_SYSTEM_TEMPLATE, {
    CONVERSATION: params.conversation,
    CONTEXT: params.context,
    LATEST_USER_REQUEST: params.latestUserRequest,
  });
}

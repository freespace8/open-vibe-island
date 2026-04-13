import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { connect } from "net";
import { homedir } from "os";

const SOCKET_PATH =
	process.env.OPEN_ISLAND_SOCKET_PATH ||
	`${process.env.HOME || homedir()}/Library/Application Support/OpenIsland/bridge.sock`;

let detectedTty: string | null = null;
try {
	const { execSync } = require("child_process");
	let walkPid = process.pid;
	for (let i = 0; i < 8; i++) {
		const info = execSync(`ps -o tty=,ppid= -p ${walkPid}`, { timeout: 1000 }).toString().trim();
		const parts = info.split(/\s+/);
		const tty = parts[0];
		const ppid = parseInt(parts[1] || "", 10);
		if (tty && tty !== "??" && tty !== "?") {
			detectedTty = `/dev/${tty}`;
			break;
		}
		if (!ppid || ppid <= 1) break;
		walkPid = ppid;
	}
} catch {}

function encodeEnvelope(command: Record<string, unknown>) {
	return JSON.stringify({ type: "command", command }) + "\n";
}

function sendToSocket(command: Record<string, unknown>) {
	return new Promise<void>((resolve) => {
		try {
			const sock = connect({ path: SOCKET_PATH }, () => {
				sock.end(encodeEnvelope(command));
			});
			sock.on("error", () => resolve());
			sock.on("close", () => resolve());
			sock.setTimeout(3000, () => {
				sock.destroy();
				resolve();
			});
		} catch {
			resolve();
		}
	});
}

function terminalFields() {
	const env = process.env;
	const result: Record<string, string> = {};
	if (env.ITERM_SESSION_ID) {
		result.terminal_app = "iTerm";
		result.terminal_session_id = env.ITERM_SESSION_ID;
	} else if (env.CMUX_WORKSPACE_ID || env.CMUX_SOCKET_PATH) {
		result.terminal_app = "cmux";
		if (env.CMUX_SURFACE_ID) result.terminal_session_id = env.CMUX_SURFACE_ID;
	} else if (env.ZELLIJ != null) {
		result.terminal_app = "Zellij";
		const paneID = env.ZELLIJ_PANE_ID || "";
		const sessionName = env.ZELLIJ_SESSION_NAME || "";
		if (paneID) result.terminal_session_id = `${paneID}:${sessionName}`;
	} else if (env.GHOSTTY_RESOURCES_DIR || (env.TERM_PROGRAM || "").toLowerCase().includes("ghostty")) {
		result.terminal_app = "Ghostty";
	} else if (env.TERM_PROGRAM === "Apple_Terminal") {
		result.terminal_app = "Terminal";
	} else if (env.TERM_PROGRAM) {
		result.terminal_app = env.TERM_PROGRAM;
	}
	if (detectedTty) result.terminal_tty = detectedTty;
	return result;
}

function pickModel(ctx: any): string | undefined {
	const model = ctx?.model;
	if (!model) return undefined;
	return model.id || model.modelId || model.name || model.label;
}

function clip(value: unknown, limit = 400): string | undefined {
	if (value == null) return undefined;
	const raw = typeof value === "string" ? value : JSON.stringify(value);
	const collapsed = raw.replace(/\s+/g, " ").trim();
	if (!collapsed) return undefined;
	return collapsed.length <= limit ? collapsed : `${collapsed.slice(0, limit - 1)}…`;
}

function extractMessageText(message: any): string | undefined {
	if (!message) return undefined;
	if (typeof message.content === "string") return clip(message.content);
	if (Array.isArray(message.content)) {
		const text = message.content
			.map((part: any) => {
				if (typeof part === "string") return part;
				if (part?.type === "text" && typeof part.text === "string") return part.text;
				if (typeof part?.content === "string") return part.content;
				return "";
			})
			.filter(Boolean)
			.join(" ");
		return clip(text);
	}
	if (typeof message.text === "string") return clip(message.text);
	return undefined;
}

function buildPayload(hookEventName: string, ctx: any, extra: Record<string, unknown> = {}) {
	const sessionManager = ctx.sessionManager;
	return {
		type: "processPiHook",
		piHook: {
			hook_event_name: hookEventName,
			session_id: sessionManager.getSessionId(),
			cwd: sessionManager.getCwd(),
			transcript_path: sessionManager.getSessionFile(),
			model: pickModel(ctx),
			...terminalFields(),
			...extra,
		},
	};
}

export default function openIslandPi(pi: ExtensionAPI) {
	pi.on("session_start", async (_event, ctx) => {
		await sendToSocket(buildPayload("SessionStart", ctx));
	});

	pi.on("input", async (event, ctx) => {
		await sendToSocket(buildPayload("UserPromptSubmit", ctx, {
			prompt: clip(event.text),
		}));
	});

	pi.on("tool_call", async (event, ctx) => {
		await sendToSocket(buildPayload("PreToolUse", ctx, {
			tool_name: event.toolName,
			tool_input: clip(event.input),
		}));
	});

	pi.on("tool_result", async (event, ctx) => {
		await sendToSocket(buildPayload("PostToolUse", ctx, {
			tool_name: event.toolName,
			tool_input: clip(event.input),
		}));
	});

	pi.on("message_end", async (event, ctx) => {
		const message = event.message as any;
		if (message?.role !== "assistant") return;
		await sendToSocket(buildPayload("Stop", ctx, {
			last_assistant_message: extractMessageText(message),
		}));
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		await sendToSocket(buildPayload("SessionEnd", ctx));
	});
}

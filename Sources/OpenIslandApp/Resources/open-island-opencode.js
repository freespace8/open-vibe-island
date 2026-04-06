// Open Island plugin for OpenCode
// Bridges OpenCode events to the Open Island desktop app via Unix socket.
// Install: copy to ~/.config/opencode/plugins/open-island.js

import { connect } from "node:net";
import { execSync } from "node:child_process";

const SOCKET_PATH =
  process.env.OPEN_ISLAND_SOCKET_PATH ||
  `/tmp/open-island-${process.getuid()}.sock`;

const SEND_TIMEOUT = 3_000;
const PERMISSION_TIMEOUT = 5 * 60 * 1_000;

function encodeEnvelope(command) {
  return JSON.stringify({ type: "command", command }) + "\n";
}

function decodeEnvelope(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function sendToSocket(json) {
  return new Promise((resolve) => {
    const sock = connect(SOCKET_PATH);
    const timeout = setTimeout(() => {
      sock.destroy();
      resolve(null);
    }, SEND_TIMEOUT);

    let buf = "";
    sock.on("data", (chunk) => {
      buf += chunk.toString();
    });
    sock.on("end", () => {
      clearTimeout(timeout);
      resolve(decodeEnvelope(buf.trim()));
    });
    sock.on("error", () => {
      clearTimeout(timeout);
      resolve(null);
    });
    sock.on("connect", () => {
      sock.end(encodeEnvelope(json));
    });
  });
}

function sendAndWaitResponse(json, timeoutMs = PERMISSION_TIMEOUT) {
  return new Promise((resolve) => {
    const sock = connect(SOCKET_PATH);
    const timeout = setTimeout(() => {
      sock.destroy();
      resolve(null);
    }, timeoutMs);

    let buf = "";
    sock.on("data", (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n").filter(Boolean);
      if (lines.length >= 2) {
        clearTimeout(timeout);
        const envelope = decodeEnvelope(lines[1]);
        sock.destroy();
        resolve(envelope);
      }
    });
    sock.on("end", () => {
      clearTimeout(timeout);
      const lines = buf.split("\n").filter(Boolean);
      resolve(lines.length >= 2 ? decodeEnvelope(lines[1]) : null);
    });
    sock.on("error", () => {
      clearTimeout(timeout);
      resolve(null);
    });
    sock.on("connect", () => {
      sock.write(encodeEnvelope(json));
    });
  });
}

function collectTerminalEnv() {
  const env = process.env;
  const result = {};
  if (env.TERM_PROGRAM) result.terminal_app = env.TERM_PROGRAM;
  if (env.ITERM_SESSION_ID) {
    result.terminal_app = "iTerm";
    result.terminal_session_id = env.ITERM_SESSION_ID;
  }
  if (env.GHOSTTY_RESOURCES_DIR) result.terminal_app = "Ghostty";
  if (env.CMUX_WORKSPACE_ID || env.CMUX_SOCKET_PATH) {
    result.terminal_app = "cmux";
    if (env.CMUX_SURFACE_ID) result.terminal_session_id = env.CMUX_SURFACE_ID;
  }

  // Try to detect TTY from parent process tree
  try {
    let pid = process.ppid;
    for (let i = 0; i < 8 && pid > 1; i++) {
      const out = execSync(`/bin/ps -p ${pid} -o tty=,ppid=`, {
        encoding: "utf8",
        timeout: 1000,
      }).trim();
      const parts = out.split(/\s+/);
      const tty = parts[0];
      if (tty && tty !== "??" && tty !== "-") {
        result.terminal_tty = tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
        break;
      }
      pid = parseInt(parts[1], 10);
      if (isNaN(pid)) break;
    }
  } catch {
    // ignore
  }

  return result;
}

function makePayload(hookEventName, sessionID, cwd, extra = {}) {
  return {
    type: "processOpenCodeHook",
    openCodeHook: {
      hook_event_name: hookEventName,
      session_id: `opencode-${sessionID}`,
      cwd: cwd || ".",
      ...collectTerminalEnv(),
      ...extra,
    },
  };
}

export default async ({ client, serverUrl }) => {
  const internalFetch =
    client?.fetch || ((url, opts) => fetch(url, opts));

  return {
    event: async (ev) => {
      try {
        const type = ev.type;
        const props = ev.properties || {};

        if (type === "session.created") {
          await sendToSocket(
            makePayload("SessionStart", props.id, props.cwd)
          );
          return;
        }

        if (type === "session.deleted") {
          await sendToSocket(
            makePayload("SessionEnd", props.id, props.cwd)
          );
          return;
        }

        if (type === "session.updated" && props.archived) {
          await sendToSocket(
            makePayload("SessionEnd", props.id, props.cwd)
          );
          return;
        }

        if (type === "session.status") {
          if (props.status === "idle") {
            await sendToSocket(
              makePayload("Stop", props.id, props.cwd, {
                last_assistant_message: props.lastAssistantMessage,
              })
            );
          }
          return;
        }

        if (type === "message.part.updated") {
          const part = props.part || {};

          // User text message
          if (part.type === "text" && props.role === "user") {
            await sendToSocket(
              makePayload("UserPromptSubmit", props.sessionID, props.cwd, {
                prompt: part.content,
              })
            );
            return;
          }

          // Tool call started
          if (part.type === "tool" && part.state === "running") {
            await sendToSocket(
              makePayload("PreToolUse", props.sessionID, props.cwd, {
                tool_name: part.toolName,
                tool_input:
                  typeof part.input === "string"
                    ? part.input
                    : JSON.stringify(part.input)?.slice(0, 200),
              })
            );
            return;
          }

          // Tool call completed
          if (part.type === "tool" && part.state === "completed") {
            await sendToSocket(
              makePayload("PostToolUse", props.sessionID, props.cwd, {
                tool_name: part.toolName,
              })
            );
            return;
          }

          return;
        }

        if (type === "permission.asked") {
          const payload = makePayload(
            "PermissionRequest",
            props.sessionID,
            props.cwd,
            {
              permission_id: props.id,
              permission_title: props.title,
              permission_description: props.description,
              tool_name: props.toolName,
              tool_input:
                typeof props.input === "string"
                  ? props.input
                  : JSON.stringify(props.input)?.slice(0, 200),
            }
          );

          const resp = await sendAndWaitResponse(payload);
          const directive = resp?.response?.directive;

          if (directive) {
            const reply =
              directive.type === "allow" ? "once" : "reject";
            const message =
              directive.type === "deny" ? directive.reason : undefined;

            try {
              await internalFetch(
                `${serverUrl}/permission/${props.id}/reply`,
                {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ reply, message }),
                }
              );
            } catch {
              // OpenCode server may have already timed out
            }
          }
          return;
        }

        if (type === "question.asked") {
          const payload = makePayload(
            "QuestionAsked",
            props.sessionID,
            props.cwd,
            {
              question_id: props.id,
              question_text: props.question,
            }
          );

          const resp = await sendAndWaitResponse(payload);
          const directive = resp?.response?.directive;

          if (directive) {
            try {
              if (directive.type === "answer") {
                await internalFetch(
                  `${serverUrl}/question/${props.id}/reply`,
                  {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      answers: [[directive.text]],
                    }),
                  }
                );
              } else {
                await internalFetch(
                  `${serverUrl}/question/${props.id}/reject`,
                  { method: "POST" }
                );
              }
            } catch {
              // OpenCode server may have already timed out
            }
          }
          return;
        }
      } catch {
        // Fail open: if Open Island is unavailable, don't block OpenCode
      }
    },

    "shell.env": async () => {
      return {
        OPEN_ISLAND_ACTIVE: "1",
      };
    },
  };
};

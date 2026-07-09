#!/usr/bin/env python3
"""Minimal, dependency-free Telegram helper for the Claude Code bridge.

Reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from the environment (stdlib only,
so plain `python3` works with no venv).

Commands:
  tg.py send-text  "<text>"
  tg.py send-video <path> "<caption>"
  tg.py send-file  <path> "<caption>"     # any document
  tg.py get-offset                        -> prints latest update_id (baseline)
  tg.py updates <since_id>                -> JSON {max, messages:[{update_id,text}]}
  tg.py poll-reply <since_id>             -> JSON of the LATEST text reply; exit 1 if none
"""
import json, os, sys, urllib.request, urllib.parse, uuid

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT = os.environ.get("TELEGRAM_CHAT_ID", "")
API = f"https://api.telegram.org/bot{TOKEN}"


def _get(method, params=None, timeout=35):
    url = f"{API}/{method}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def send_text(text):
    # Telegram caps messages at 4096 chars; trim defensively.
    data = urllib.parse.urlencode({"chat_id": CHAT, "text": text[:4096]}).encode()
    with urllib.request.urlopen(f"{API}/sendMessage", data=data, timeout=35) as r:
        return json.load(r)


def _post(method, params):
    data = urllib.parse.urlencode(params).encode()
    with urllib.request.urlopen(f"{API}/{method}", data=data, timeout=35) as r:
        return json.load(r)


def set_keyboard(buttons, text="⌨️ Quick buttons below."):
    """Show a persistent reply keyboard (one button per row). Tapping a button
    sends its label as a normal message, which the bridge acts on. Persists
    across later messages until replaced."""
    rows = [buttons[i:i + 2] for i in range(0, len(buttons), 2)]
    kb = {"keyboard": rows, "resize_keyboard": True, "is_persistent": True}
    return _post("sendMessage", {"chat_id": CHAT, "text": text,
                                 "reply_markup": json.dumps(kb, ensure_ascii=False)})


def set_commands(pairs):
    """Register the bot's / command menu (the ☰ button). pairs: (cmd, description)."""
    cmds = [{"command": c, "description": d} for c, d in pairs]
    return _post("setMyCommands", {"commands": json.dumps(cmds, ensure_ascii=False)})


def send_action(action="typing"):
    """Show a chat action (e.g. 'typing') for a few seconds."""
    return _post("sendChatAction", {"chat_id": CHAT, "action": action})


def _send_multipart(method, field_name, path, caption, content_type):
    boundary = "----tg" + uuid.uuid4().hex

    def field(name, val):
        return (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
                f'\r\n\r\n{val}\r\n').encode()

    body = b"" + field("chat_id", CHAT) + field("caption", caption)
    fn = os.path.basename(path)
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{field_name}"; '
             f'filename="{fn}"\r\nContent-Type: {content_type}\r\n\r\n').encode()
    with open(path, "rb") as f:
        body += f.read()
    body += (f'\r\n--{boundary}--\r\n').encode()
    req = urllib.request.Request(
        f"{API}/{method}", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)


def send_video(path, caption=""):
    return _send_multipart("sendVideo", "video", path, caption, "video/mp4")


def send_file(path, caption=""):
    return _send_multipart("sendDocument", "document", path, caption,
                           "application/octet-stream")


def get_offset():
    d = _get("getUpdates", {"timeout": 0})
    ids = [u["update_id"] for u in d.get("result", [])]
    return max(ids) if ids else 0


def updates(since, poll_timeout=0):
    """{'max': highest_update_id, 'messages': [{update_id, text}]} for text
    messages from our chat after `since`. `max` covers ALL updates so the caller
    can advance its offset even past non-chat updates. poll_timeout>0 turns this
    into a long-poll: Telegram holds the connection open until a message arrives
    or the timeout elapses (near-instant response, no busy loop)."""
    poll_timeout = int(poll_timeout)
    d = _get("getUpdates", {"offset": int(since) + 1, "timeout": poll_timeout},
             timeout=poll_timeout + 15)
    res = d.get("result", [])
    mx = int(since)
    msgs = []
    for u in res:
        mx = max(mx, u["update_id"])
        m = u.get("message") or u.get("edited_message") or {}
        chat = str(m.get("chat", {}).get("id", ""))
        text = m.get("text")
        if chat == str(CHAT) and text:
            msgs.append({"update_id": u["update_id"], "text": text})
    return {"max": mx, "messages": msgs}


def poll_reply(since):
    d = _get("getUpdates", {"offset": int(since) + 1, "timeout": 0})
    latest = None
    for u in d.get("result", []):
        m = u.get("message") or u.get("edited_message") or {}
        chat = str(m.get("chat", {}).get("id", ""))
        text = m.get("text")
        if chat == str(CHAT) and text:
            if latest is None or u["update_id"] > latest["update_id"]:
                latest = {"update_id": u["update_id"], "text": text}
    return latest


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "send-text":
        print(json.dumps(send_text(sys.argv[2])))
    elif cmd == "send-video":
        print(json.dumps(send_video(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")))
    elif cmd == "send-file":
        print(json.dumps(send_file(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")))
    elif cmd == "get-offset":
        print(get_offset())
    elif cmd == "updates":
        pt = sys.argv[3] if len(sys.argv) > 3 else 0
        print(json.dumps(updates(sys.argv[2], pt), ensure_ascii=False))
    elif cmd == "poll-reply":
        r = poll_reply(sys.argv[2])
        if r:
            print(json.dumps(r, ensure_ascii=False))
            sys.exit(0)
        sys.exit(1)
    elif cmd == "set-keyboard":
        if len(sys.argv) < 3:
            sys.stderr.write("usage: tg.py set-keyboard <button> [button ...]\n"); sys.exit(2)
        print(json.dumps(set_keyboard(sys.argv[2:]), ensure_ascii=False))
    elif cmd == "set-commands":
        pairs = [a.split(":", 1) for a in sys.argv[2:]]
        print(json.dumps(set_commands(pairs), ensure_ascii=False))
    elif cmd == "send-action":
        print(json.dumps(send_action(sys.argv[2] if len(sys.argv) > 2 else "typing")))
    else:
        sys.stderr.write("usage: tg.py send-text|send-video|send-file|get-offset|updates|poll-reply\n")
        sys.exit(2)


if __name__ == "__main__":
    main()

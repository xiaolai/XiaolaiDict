#!/usr/bin/env python3
"""The provider stage's stand-in for an OpenAI-compatible endpoint, and the judge of what it was sent (ADR-0053).

    provider-stub.py serve <log> <port-file>
        Answers `POST …/chat/completions` on 127.0.0.1, on a port the system chooses, written to <port-file> once it
        listens. Every request is one JSON line in <log>: the model asked for, what kind of question it was, the system
        and user messages, and **whether** a key came — never the key. Runs until it is ended.

    provider-stub.py claude <log> [<claude's own arguments>…]
        A stand-in for the reader's `claude`, started by the app exactly as it starts theirs: `stream-json` in and out,
        one `result` a turn. Every turn is one JSON line in the same <log>, in the shape `serve` writes, its model the
        one the app passed with `--model` and its `user` the whole turn — the instructions travel in the turn.

    provider-stub.py judge <log> <tier> <model> <sentence> [<senses-model>]
        PASS and FAIL lines, then DONE — the format `consume_verdicts` reads — about the requests asked for <model>:
        `onThisMac`, it was asked to pick a sense and told the sense with an explanation, each carrying <sentence>;
        `remote`, it was asked nothing that carries the dictionary's text — no sense question, no `Dictionary sense:`
        line, and none of the senses the <senses-model> arm was sent — and its explanation carried <sentence>;
        `refused`, nothing at all arrived for it.

**How the tiers are reached without a packet leaving the Mac.** The app decides the tier from the source alone, failing
closed (`RemoteDisclosure`): an endpoint on `127.0.0.1` is on this Mac, and the reader's CLI is remote wherever it is
installed. A remote *endpoint* must be HTTPS — plain HTTP off this Mac is never sent (`EndpointAddress`), and this stub
has no certificate the app would trust — so the remote tier is observed through the CLI instead: the stage installs this
script as the reader's `claude`, and its turns land in the same log, told apart by the model each arm asks for. A URL
the app must refuse — one carrying a userinfo, `http://e2e@localhost:<port>/v1` — is the `refused` arm: it reaches this
server if it is sent at all. No connection is made to a LAN address, which would raise macOS's Local Network prompt on a
screen nobody watches.

The publisher's text is looked for the way `RemoteDisclosure.leaks` looks for it: the first 32 characters of each sense
as the sense prompt carried it, at least 8 of them, and not where the reader's own sentence already holds them. A
verdict names a sense by its number, never by its text: a run log is not a place for a dictionary's words.

Python 3.9, which is `/usr/bin/python3` on the E2E Mac: nothing newer is used.
"""
from __future__ import annotations

import http.server
import json
import os
import pathlib
import re
import sys
import threading

HOST = "127.0.0.1"

# The first line of each of `ModelPrompt`'s instructions, which is how a question is told apart. `test_provider_stub`
# reads them out of `ModelPrompt.swift`, so a reworded instruction fails there and not as a stage that never saw one.
SENSE_OPENING = "You identify which dictionary sense of a word"
EXPLANATION_OPENING = "You explain how one word is being used"
TRANSLATION_OPENING = "Translate the user"

# One token, so `EndToEndTextTests` cannot mistake the harness looking for it for the app's own words.
MARKER = "xiaolaidict-e2e-stub-explanation"
ANSWERS = {
    # `SenseAnswer.parse` reads the first run of digits: the first sense, which every list has.
    "sense": "1",
    "explanation": f"{MARKER}: here the word names people coming together, said of when they stopped doing so.",
    "translation": "xiaolaidict-e2e-stub-translation",
    # `CLIPreflight.question`: "Reply with the single word: ready".
    "question": "ready",
}

# What `RemoteDisclosure` probes: the first `probeLength` characters, and nothing shorter than `minimumProbe`.
PROBE_LENGTH = 32
MINIMUM_PROBE = 8


def classify(body: dict) -> str:
    """Which question a chat completion asks, by its system message — the app's own instructions."""
    system = next((message.get("content", "") for message in body.get("messages", [])
                   if isinstance(message, dict) and message.get("role") == "system"), "")
    return kind_of(system, lambda text, opening: text.startswith(opening))


def classify_turn(text: str) -> str:
    """Which question a CLI's turn asks: its instructions travel in the turn, after a preface (`ResidentTurn.text`)."""
    return kind_of(text, lambda turn, opening: any(line.startswith(opening) for line in turn.split("\n")))


def kind_of(text: str, opens) -> str:
    if opens(text, SENSE_OPENING):
        return "sense"
    if opens(text, EXPLANATION_OPENING):
        return "explanation"
    if opens(text, TRANSLATION_OPENING):
        return "translation"
    return "question"


def answer(kind: str) -> str:
    return ANSWERS[kind]


def completion(text: str, model: str) -> dict:
    """A chat completion in the shape `ChatCompletionsWire.Completion` decodes."""
    return {"id": "xiaolaidict-e2e", "object": "chat.completion", "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]}


# ---------------------------------------------------------------------------------------------------------------------
# serve

class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1, with a length on every answer: the provider keeps one connection for its life (plan §5), and a server
    # that closed after each answer would make the app pay a reconnection the product never does.
    protocol_version = "HTTP/1.1"
    log_path: pathlib.Path = pathlib.Path("/dev/null")
    lock = threading.Lock()

    def log_message(self, *_):
        pass  # The log is the JSON lines; the default writes every request to stderr.

    def send(self, status: int, payload: dict):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send(405, {"error": {"message": "POST only", "code": "method_not_allowed"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.send(404, {"error": {"message": "not a chat completion", "code": "not_found"}})
            return
        try:
            body = json.loads(raw)
            messages = body["messages"]
            model = str(body.get("model", ""))
        except (ValueError, KeyError, TypeError):
            self.send(400, {"error": {"message": "not a chat completion request", "code": "invalid_request"}})
            return
        kind = classify(body)
        entry = {
            "path": self.path, "model": model, "kind": kind,
            "system": next((m.get("content", "") for m in messages if isinstance(m, dict) and m.get("role") == "system"),
                           ""),
            "user": "\n".join(str(m.get("content", "")) for m in messages if isinstance(m, dict) and m.get("role") == "user"),
            # Whether a key came, and never what it was.
            "authorized": self.headers.get("Authorization") is not None,
        }
        with self.lock, open(self.log_path, "a") as log:
            log.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.send(200, completion(answer(kind), model))


def serve(log: str, port_file: str) -> int:
    Handler.log_path = pathlib.Path(log)
    Handler.log_path.write_text("")
    server = http.server.ThreadingHTTPServer((HOST, 0), Handler)
    server.daemon_threads = True
    # Written once it listens, and whole: the stage waits for this file, and a half-written port is a wrong one.
    staged = pathlib.Path(port_file + ".partial")
    staged.write_text(f"{server.server_address[1]}\n")
    os.replace(staged, port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


# ---------------------------------------------------------------------------------------------------------------------
# claude

def model_of(arguments: list) -> str:
    """The model the app started `claude` with: the word after `--model`."""
    for index, argument in enumerate(arguments[:-1]):
        if argument == "--model":
            return arguments[index + 1]
    return ""


def claude(log: str, arguments: list, stdin=sys.stdin, stdout=sys.stdout) -> int:
    """`claude -p --input-format stream-json --output-format stream-json`, as `ClaudeCLIWire` reads it: an `init` line on
    the first turn, an `assistant` line, and a `result` that says it did not fail."""
    if arguments == ["--version"]:
        stdout.write("9.9.9 (xiaolaidict e2e stub)\n")
        return 0
    model = model_of(arguments)
    turns = 0
    for line in stdin:
        try:
            text = str(json.loads(line)["message"]["content"])
        except (ValueError, KeyError, TypeError):
            continue
        turns += 1
        kind = classify_turn(text)
        entry = {"path": "claude", "model": model, "kind": kind, "system": "", "user": text, "authorized": False}
        with open(log, "a") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        said = answer(kind)
        if turns == 1:
            stdout.write(json.dumps({"type": "system", "subtype": "init"}) + "\n")
        stdout.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": said}]}}) + "\n")
        stdout.write(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": said}) + "\n")
        stdout.flush()
    return 0


# ---------------------------------------------------------------------------------------------------------------------
# judge

def read_log(path) -> list:
    with open(path) as log:
        return [json.loads(line) for line in log if line.strip()]


def senses_in(prompt: str) -> list:
    """The numbered senses a sense prompt carried (`ModelPrompt.sense`), in order, each as the prompt wrote it."""
    found, inside = [], False
    for line in prompt.split("\n"):
        if line == "Senses:":
            inside = True
        elif inside and line == "Which number?":
            break
        elif inside:
            numbered = re.match(r"(\d+)\. (.*)$", line)
            if numbered:
                found.append(numbered.group(2))
    return found


def probes(senses: list, sentence: str) -> list:
    """(sense number, probe) for every sense worth looking for: its opening, long enough to be the publisher's and
    nobody else's, and not something the reader's own sentence holds."""
    looked = []
    for number, text in enumerate(senses, 1):
        probe = text[:PROBE_LENGTH].strip()
        if len(probe) >= MINIMUM_PROBE and probe not in sentence:
            looked.append((number, probe))
    return looked


def sentence_of(prompt: str) -> str:
    return next((line[len("Sentence: "):] for line in prompt.split("\n") if line.startswith("Sentence: ")), "")


def judge(entries: list, tier: str, model: str, sentence: str, senses_model: str | None = None) -> list:
    verdicts = []

    def say(ok: bool, good: str, bad: str):
        verdicts.append(("PASS\t" if ok else "FAIL\t") + (good if ok else bad))

    asked = [entry for entry in entries if entry.get("model") == model]
    if tier == "refused":
        say(not asked, f"provider: the refused endpoint was sent nothing ({model})",
            f"provider: the refused endpoint was sent {len(asked)} request(s) ({model})")
        return verdicts + ["DONE"]
    label = f"provider: the {'on-this-Mac endpoint' if tier == 'onThisMac' else 'remote source'}"
    if not asked:
        say(False, "", f"{label} was asked nothing ({model})")
        return verdicts + ["DONE"]
    kinds = sorted({entry.get("kind", "?") for entry in asked})
    sensed = [entry for entry in asked if entry.get("kind") == "sense"]
    explained = [entry for entry in asked if entry.get("kind") == "explanation"]

    if tier == "onThisMac":
        if not sensed:
            say(False, "", f"{label}: a lookup asked it no sense question ({len(asked)} request(s): {kinds})")
        else:
            carried = [entry for entry in sensed if sentence in entry.get("user", "")]
            say(bool(carried),
                f"{label} was asked to pick a sense, with the reader's sentence and "
                f"{len(senses_in(sensed[-1].get('user', '')))} senses",
                f"{label} was asked to pick a sense without the reader's sentence")
        if not explained:
            say(False, "", f"{label}: the explanation was never asked of it ({kinds})")
        else:
            last = explained[-1].get("user", "")
            say(sentence in last, f"{label}: the explanation carried the reader's sentence",
                f"{label}: the explanation did not carry the reader's sentence")
            # The positive control the remote arm is measured against: on this Mac the explanation is told the sense.
            told = any(line.startswith("Dictionary sense: ") for line in last.split("\n"))
            say(told, f"{label}: the explanation was told the dictionary's sense, as on this Mac it may be",
                f"{label}: the explanation was not told the sense, so the remote arm's lack of one would prove nothing")
        return verdicts + ["DONE"]

    # remote
    listed = [entry for entry in entries if entry.get("model") == senses_model and entry.get("kind") == "sense"]
    senses = senses_in(listed[-1].get("user", "")) if listed else []
    looked = probes(senses, sentence)
    if not looked:
        say(False, "", f"{label}: nothing to look for — the on-this-Mac arm was sent no senses, so finding none here "
                       "would prove nothing")
    for entry in sensed:
        say(False, "", f"{label} was asked to pick a sense, which sends the dictionary's text off the Mac")
    leaks = []
    for entry in asked:
        text = entry.get("system", "") + "\n" + entry.get("user", "")
        own = sentence_of(entry.get("user", ""))
        found = [number for number, probe in looked if probe in text and probe not in own]
        if found:
            leaks.append(f"{entry.get('kind')} carried sense {', sense '.join(map(str, found))}")
        if any(line.startswith("Dictionary sense: ") for line in entry.get("user", "").split("\n")):
            leaks.append(f"{entry.get('kind')} carried a Dictionary sense line")
    if looked:
        say(not leaks, f"{label} was sent none of the {len(looked)} senses the on-this-Mac arm was "
                       f"({len(asked)} request(s): {kinds})",
            f"{label} was sent the dictionary's text: {'; '.join(leaks)}")
    carried = [entry for entry in explained if sentence in entry.get("user", "")]
    say(bool(carried), f"{label}: the explanation carried the reader's sentence, and only that",
        f"{label}: no explanation carrying the reader's sentence arrived ({kinds})")
    return verdicts + ["DONE"]


def main(argv: list) -> int:
    if len(argv) == 4 and argv[1] == "serve":
        return serve(argv[2], argv[3])
    if len(argv) >= 3 and argv[1] == "claude":
        return claude(argv[2], argv[3:])
    if len(argv) in (6, 7) and argv[1] == "judge" and argv[3] in ("onThisMac", "remote", "refused"):
        try:
            entries = read_log(argv[2])
        except (OSError, ValueError) as error:
            print(f"FAIL\tprovider: the stub's log could not be read: {error}")
            print("DONE")
            return 0
        print("\n".join(judge(entries, argv[3], argv[4], argv[5], argv[6] if len(argv) == 7 else None)))
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

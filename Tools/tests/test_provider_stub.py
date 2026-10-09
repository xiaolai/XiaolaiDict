"""The provider stage's stand-in endpoint, and its judgement of what it was sent (ADR-0053, plan §8 P5).

The `provider` stage points the app at `Tools/e2e/provider-stub.py` — an OpenAI-compatible server on 127.0.0.1 under a
URL the app reads as **on this Mac**, under one it must **refuse**, and as the reader's own `claude`, which is
**remote** — then asks the stub what arrived. Whether the remote arm carried the dictionary's text is the stage's whole point, and that judgement is made
here, in Python the E2E Mac runs, ten minutes into a run. So it is held on this Mac first: the stub's answers against
the rules the app reads them by, its wire against a real socket, and every verdict against a log built by hand — the
honest arms pass, and each way a remote request could carry a publisher's text is refused by name.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import http.client
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from ledger_schema import REPO

STUB = REPO / "Tools" / "e2e" / "provider-stub.py"
_spec = importlib.util.spec_from_file_location("provider_stub", STUB)
stub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stub)

PROMPTS = REPO / "Sources" / "ModelKit" / "ModelPrompt.swift"
SENTENCE = "The meeting ended after we stopped meeting at noon."
# Three senses in the shape `ModelPrompt.sense` writes them: invented here, never a publisher's text.
SENSES = [
    "arrange or happen to come into the presence or company of someone",
    "come together in the same place for a purpose, as a committee or a group of friends does",
    "touch or join something else at a point where two things come into contact",
]


def swift_literal(name: str) -> str:
    """`ModelPrompt.<name>`, a multi-line literal, as the compiler hands it over: continuation backslashes joined."""
    found = re.search(rf'static let {name} = """\n(.*?)\n\s*"""', PROMPTS.read_text(), re.DOTALL)
    assert found, f"ModelPrompt.swift declares no {name}"
    lines = [line.strip() for line in found.group(1).split("\n")]
    return "\n".join(lines).replace("\\\n", "")


def sense_prompt(sentence: str = SENTENCE, senses: list[str] | None = None) -> str:
    lines = [f"Sentence: {sentence}", "Senses:"]
    lines += [f"{index}. {text}" for index, text in enumerate(senses or SENSES, 1)]
    return "\n".join(lines + ["Which number?"])


def explanation_prompt(sentence: str = SENTENCE, sense: str | None = None) -> str:
    lines = [f"Sentence: {sentence}", "Word: meeting"]
    if sense is not None:
        lines.append(f"Dictionary sense: {sense}")
    return "\n".join(lines + ["Explain how the word is being used in this sentence, in two or three sentences."])


def body(model: str, system: str | None, user: str) -> dict:
    messages = ([{"role": "system", "content": system}] if system is not None else []) + [
        {"role": "user", "content": user}]
    return {"model": model, "messages": messages, "temperature": 0, "max_completion_tokens": 16}


def logged(model: str, kind: str, user: str, system: str = "") -> dict:
    """One line of the stub's log, as `serve` writes it."""
    return {"path": "/v1/chat/completions", "model": model, "kind": kind, "system": system, "user": user,
            "authorized": False}


def lines_of(verdicts: list[str], kind: str) -> list[str]:
    return [line.split("\t", 1)[1] for line in verdicts if line.startswith(kind + "\t")]


# ---------------------------------------------------------------------------------------------------------------------

class TheStubAnswersAsTheAppReads(unittest.TestCase):
    """Each question gets the answer the app's own reader takes: a sense number `SenseAnswer` reads, an explanation
    that is not the sentence handed back, the preflight's word."""

    def test_the_questions_are_told_apart_by_the_apps_own_instructions(self):
        # Read from the Swift literals, so a reworded instruction fails here rather than as a stage that never sees a
        # sense question and calls the app wrong.
        self.assertEqual(stub.classify(body("m", swift_literal("senseInstructions"), sense_prompt())), "sense")
        self.assertEqual(stub.classify(body("m", swift_literal("explanationInstructions"), explanation_prompt())),
                         "explanation")
        self.assertEqual(stub.classify(body("m", "Translate the user's text into natural, fluent Chinese.", SENTENCE)),
                         "translation")
        # The preflight's trivial question carries no instructions at all (`CLIPreflight.question`).
        self.assertEqual(stub.classify(body("m", None, "Reply with the single word: ready")), "question")

    def test_a_sense_answer_is_a_number_the_app_reads_as_the_first_sense(self):
        answer = stub.answer("sense")
        # `SenseAnswer.parse`: the first non-empty line, up to its first full stop, the first run of digits.
        first = next(line.strip() for line in answer.splitlines() if line.strip()).split(".")[0]
        self.assertEqual(re.search(r"\d+", first).group(0), "1")

    def test_an_explanation_is_not_the_sentence_and_carries_the_marker(self):
        answer = stub.answer("explanation")
        self.assertIn(stub.MARKER, answer)
        self.assertNotIn(SENTENCE.lower(), answer.lower())
        # One token, not prose: `EndToEndTextTests` would read a sentence the harness greps for as the app's own words.
        self.assertNotIn(" ", stub.MARKER)

    def test_the_preflight_is_answered_ready(self):
        self.assertEqual(stub.answer("question"), "ready")


class TheStubOnARealSocket(unittest.TestCase):
    """`serve`, as the stage starts it: a port of the system's choosing written once it listens, one JSON line per
    request, and a chat completion back in the shape `ChatCompletionsWire.Completion` decodes."""

    def setUp(self):
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-stub-"))
        self.addCleanup(shutil.rmtree, self.scratch, True)
        self.log, self.port_file = self.scratch / "stub.jsonl", self.scratch / "stub.port"
        self.server = subprocess.Popen([sys.executable, str(STUB), "serve", str(self.log), str(self.port_file)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop)
        for _ in range(100):
            if self.port_file.exists() and self.port_file.read_text().strip():
                break
            time.sleep(0.05)
        self.port = int(self.port_file.read_text().strip())

    def stop(self):
        self.server.terminate()
        self.server.communicate(timeout=10)

    def post(self, payload, *, path="/v1/chat/completions", headers=None) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        connection.request("POST", path, body=data, headers={"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        try:
            return response.status, response.read()
        finally:
            connection.close()

    def test_a_completion_comes_back_in_the_shape_the_app_decodes_and_is_logged(self):
        status, raw = self.post(body("xiaolaidict-e2e-onthismac", swift_literal("senseInstructions"), sense_prompt()))
        self.assertEqual(status, 200)
        choice = json.loads(raw)["choices"][0]
        self.assertEqual(choice["message"]["content"], stub.answer("sense"))
        self.assertEqual(choice["finish_reason"], "stop")
        entries = stub.read_log(self.log)
        self.assertEqual([(e["model"], e["kind"]) for e in entries], [("xiaolaidict-e2e-onthismac", "sense")])
        self.assertIn(SENTENCE, entries[0]["user"])

    def test_the_log_says_whether_a_key_came_and_never_what_it_was(self):
        status, _ = self.post(body("m", None, "Reply with the single word: ready"),
                              headers={"Authorization": "Bearer sk-e2e-never-logged"})
        self.assertEqual(status, 200)
        self.assertTrue(stub.read_log(self.log)[0]["authorized"])
        self.assertNotIn("sk-e2e-never-logged", self.log.read_text())

    def test_anything_but_a_chat_completion_is_refused(self):
        self.assertEqual(self.post(body("m", None, "x"), path="/v1/embeddings")[0], 404)
        self.assertEqual(self.post(b"{not json")[0], 400)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(connection.close)
        connection.request("GET", "/v1/chat/completions")
        self.assertEqual(connection.getresponse().status, 405)
        self.assertEqual(stub.read_log(self.log), [], "a refused request was logged as one the app made")

    def test_one_kept_connection_answers_several_questions(self):
        # The provider keeps one `URLSession` and reuses its connection (plan §5); a stub that closed after each answer
        # would make the app pay a reconnection the product never does.
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(connection.close)
        for _ in range(3):
            connection.request("POST", "/v1/chat/completions", body=json.dumps(body("m", None, "q")).encode(),
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.read()
        self.assertEqual(len(stub.read_log(self.log)), 3)

    def test_it_listens_on_loopback_alone(self):
        self.assertEqual(stub.HOST, "127.0.0.1")


class TheJudgementOfWhatArrived(unittest.TestCase):
    """`judge`: PASS and FAIL lines and a final DONE, the format `consume_verdicts` reads."""

    ON = "xiaolaidict-e2e-onthismac"
    OFF = "xiaolaidict-e2e-remote"
    SENSE = swift_literal("senseInstructions")
    EXPLAIN = swift_literal("explanationInstructions")

    def on_this_mac(self) -> list[dict]:
        return [logged(self.ON, "question", "Reply with the single word: ready"),
                logged(self.ON, "sense", sense_prompt(), self.SENSE),
                logged(self.ON, "explanation", explanation_prompt(sense=SENSES[0]), self.EXPLAIN)]

    def remote(self, explanation: str | None = None) -> list[dict]:
        return [logged(self.OFF, "question", "Reply with the single word: ready"),
                logged(self.OFF, "explanation", explanation or explanation_prompt(), self.EXPLAIN)]

    def test_the_honest_on_this_mac_arm_passes(self):
        verdicts = stub.judge(self.on_this_mac(), "onThisMac", self.ON, SENTENCE)
        self.assertEqual(verdicts[-1], "DONE")
        self.assertEqual(lines_of(verdicts, "FAIL"), [])
        self.assertGreaterEqual(len(lines_of(verdicts, "PASS")), 3)

    def test_an_on_this_mac_arm_never_asked_a_sense_is_refused(self):
        entries = [entry for entry in self.on_this_mac() if entry["kind"] != "sense"]
        failed = lines_of(stub.judge(entries, "onThisMac", self.ON, SENTENCE), "FAIL")
        self.assertTrue(any("no sense question" in line for line in failed), failed)

    def test_an_on_this_mac_explanation_without_its_sense_is_refused(self):
        # The positive control: on this Mac the explanation is told the sense. Without it, the remote arm's
        # explanation lacking one would prove nothing.
        entries = self.on_this_mac()[:2] + [logged(self.ON, "explanation", explanation_prompt(), self.EXPLAIN)]
        failed = lines_of(stub.judge(entries, "onThisMac", self.ON, SENTENCE), "FAIL")
        self.assertTrue(any("not told the sense" in line for line in failed), failed)

    def test_an_arm_that_never_saw_the_readers_sentence_is_refused(self):
        entries = self.on_this_mac() + self.remote(explanation_prompt(sentence="Something else entirely here."))
        failed = lines_of(stub.judge(entries, "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("sentence" in line for line in failed), failed)

    def test_the_honest_remote_arm_passes(self):
        verdicts = stub.judge(self.on_this_mac() + self.remote(), "remote", self.OFF, SENTENCE, self.ON)
        self.assertEqual(verdicts[-1], "DONE")
        self.assertEqual(lines_of(verdicts, "FAIL"), [])

    def test_a_remote_explanation_carrying_a_sense_is_refused_by_its_number(self):
        planted = self.remote(explanation_prompt(sense=SENSES[1]))
        failed = lines_of(stub.judge(self.on_this_mac() + planted, "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("sense 2" in line for line in failed), failed)
        # The publisher's text is named by its number, never quoted into a run log.
        self.assertFalse(any(SENSES[1][:20] in line for line in failed), failed)

    def test_a_sense_cut_or_unflattened_is_still_found(self):
        # A prefix of every cut a prompt makes, and the text as written — the two forms `RemoteDisclosure.leaks` probes.
        for carried in (SENSES[2][:40], SENSES[2][:32] + "\nand the rest"):
            with self.subTest(carried=carried):
                planted = self.remote(explanation_prompt() + "\n" + carried)
                failed = lines_of(stub.judge(self.on_this_mac() + planted, "remote", self.OFF, SENTENCE, self.ON),
                                  "FAIL")
                self.assertTrue(any("sense 3" in line for line in failed), failed)

    def test_a_remote_sense_question_is_refused(self):
        planted = self.remote() + [logged(self.OFF, "sense", sense_prompt(), self.SENSE)]
        failed = lines_of(stub.judge(self.on_this_mac() + planted, "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("asked to pick a sense" in line for line in failed), failed)

    def test_a_dictionary_sense_line_is_refused_whatever_it_holds(self):
        planted = self.remote(explanation_prompt(sense="words nobody in this log ever wrote down"))
        failed = lines_of(stub.judge(self.on_this_mac() + planted, "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("Dictionary sense" in line for line in failed), failed)

    def test_a_remote_arm_with_no_senses_to_look_for_is_refused_not_passed(self):
        # Nothing to look for is not nothing found: with no on-this-Mac sense list the absence proves nothing.
        failed = lines_of(stub.judge(self.remote(), "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("nothing to look for" in line for line in failed), failed)

    def test_a_remote_arm_that_sent_nothing_is_refused(self):
        failed = lines_of(stub.judge(self.on_this_mac(), "remote", self.OFF, SENTENCE, self.ON), "FAIL")
        self.assertTrue(any("asked nothing" in line for line in failed), failed)

    def test_the_readers_own_words_are_not_looked_for(self):
        # A sense whose opening the reader's sentence already holds sends nothing of the publisher's.
        own = "The meeting ended after we stopped"
        senses = [own + " and other words of a sense", SENSES[1]]
        entries = [logged(self.ON, "sense", sense_prompt(senses=senses), self.SENSE),
                   logged(self.ON, "explanation", explanation_prompt(sense=SENSES[1]), self.EXPLAIN)]
        verdicts = stub.judge(entries + self.remote(), "remote", self.OFF, SENTENCE, self.ON)
        self.assertEqual(lines_of(verdicts, "FAIL"), [])

    def test_the_command_line_prints_the_verdicts_and_done(self):
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-stub-judge-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        log = scratch / "stub.jsonl"
        log.write_text("".join(json.dumps(entry) + "\n" for entry in self.on_this_mac() + self.remote()))
        done = subprocess.run([sys.executable, str(STUB), "judge", str(log), "remote", self.OFF, SENTENCE, self.ON],
                              capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip().splitlines()[-1], "DONE")
        self.assertTrue(done.stdout.startswith("PASS\t"), done.stdout)


class TheStandInClaude(unittest.TestCase):
    """`claude`: the stage installs the stub as the reader's `claude`, the remote tier's transport. It must speak what
    `ClaudeCLIWire` reads — a `result` that says it did not fail, carrying the answer — and log each turn as `serve`
    logs a request, its model the one the app passed and its kind read from the instructions inside the turn."""

    PREFACE = "This is an unrelated question; ignore earlier messages."

    def turn(self, instructions: str, prompt: str) -> str:
        """A turn as `ResidentTurn.text` writes one."""
        return "\n\n".join(part for part in (self.PREFACE, instructions, prompt) if part)

    def run_claude(self, turns: list[str], *arguments: str) -> tuple[list[dict], list[dict]]:
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-stub-claude-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        log = scratch / "stub.jsonl"
        lines = "".join(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n"
                        for text in turns)
        done = subprocess.run([sys.executable, str(STUB), "claude", str(log), *arguments], input=lines,
                              capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        written = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
        entries = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return written, entries

    def test_each_turn_ends_in_a_result_that_says_it_did_not_fail(self):
        explain = self.turn(swift_literal("explanationInstructions"), explanation_prompt())
        written, _ = self.run_claude(["Reply with the single word: ready", explain], "-p", "--model", "m")
        results = [line for line in written if line.get("type") == "result"]
        self.assertEqual(len(results), 2)
        # `ClaudeCLIWire` reads success only where `is_error` says so.
        self.assertTrue(all(line.get("is_error") is False for line in results), results)
        self.assertEqual(results[0]["result"], "ready")
        self.assertIn(stub.MARKER, results[1]["result"])
        self.assertEqual(sum(line.get("type") == "system" for line in written), 1, "an init line on the first turn")

    def test_each_turn_is_logged_as_a_request_with_the_apps_model_and_its_kind(self):
        sense = self.turn(swift_literal("senseInstructions"), sense_prompt())
        explain = self.turn(swift_literal("explanationInstructions"), explanation_prompt())
        _, entries = self.run_claude([sense, explain], "-p", "--verbose", "--model", "xiaolaidict-e2e-remote")
        self.assertEqual([entry["model"] for entry in entries], ["xiaolaidict-e2e-remote"] * 2)
        self.assertEqual([entry["kind"] for entry in entries], ["sense", "explanation"])
        self.assertEqual(entries[1]["user"], explain, "the whole turn, instructions and all, is what is judged")

    def test_its_turns_are_judged_as_the_remote_arm(self):
        explain = self.turn(swift_literal("explanationInstructions"), explanation_prompt())
        _, entries = self.run_claude(["Reply with the single word: ready", explain], "--model", "remote-cli")
        on = TheJudgementOfWhatArrived().on_this_mac()
        verdicts = stub.judge(on + entries, "remote", "remote-cli", SENTENCE, TheJudgementOfWhatArrived.ON)
        self.assertEqual(lines_of(verdicts, "FAIL"), [])
        planted = self.turn(swift_literal("explanationInstructions"), explanation_prompt(sense=SENSES[0]))
        _, leaky = self.run_claude([planted], "--model", "remote-cli")
        failed = lines_of(stub.judge(on + leaky, "remote", "remote-cli", SENTENCE, TheJudgementOfWhatArrived.ON), "FAIL")
        self.assertTrue(any("Dictionary sense" in line or "sense 1" in line for line in failed), failed)

    def test_its_version_is_one_the_app_reads(self):
        done = subprocess.run([sys.executable, str(STUB), "claude", "/dev/null", "--version"], capture_output=True,
                              text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertRegex(done.stdout, r"^\d+\.\d+")


class TheRefusedArm(unittest.TestCase):
    """`judge … refused`: the endpoint the app must refuse to send to was sent nothing."""

    def test_nothing_arrived_passes(self):
        entries = TheJudgementOfWhatArrived().on_this_mac()
        verdicts = stub.judge(entries, "refused", "xiaolaidict-e2e-refused", SENTENCE)
        self.assertEqual(verdicts[-1], "DONE")
        self.assertEqual(lines_of(verdicts, "FAIL"), [])
        self.assertEqual(len(lines_of(verdicts, "PASS")), 1)

    def test_anything_arriving_fails(self):
        entries = [logged("xiaolaidict-e2e-refused", "question", "Reply with the single word: ready")]
        failed = lines_of(stub.judge(entries, "refused", "xiaolaidict-e2e-refused", SENTENCE), "FAIL")
        self.assertTrue(any("was sent 1 request" in line for line in failed), failed)

if __name__ == "__main__":
    unittest.main()

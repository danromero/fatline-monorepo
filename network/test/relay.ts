import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";

/** A stand-in relay for the notification tests, which opens nothing. */

export interface Sent {
  handle: string;
  sealed: string;
  collapse?: string;
}

/** Stands in for a relay's POST /send: keeps each call's notes, and answers which handles are gone. */
export class FakeRelay {
  readonly gone = new Set<string>();
  /** Why a handle's note didn't reach Apple, as the relay's `failed` says. */
  readonly failed = new Map<string, string>();
  /** What it answers. Anything but 200 refuses the notes. */
  status = 200;
  /** Anything a call got wrong about the relay's contract. */
  readonly problems: string[] = [];
  private readonly calls: Sent[][] = [];
  private readonly server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => (body += chunk));
    request.on("end", () => {
      if (request.method !== "POST" || request.url !== "/send") this.problems.push(`${request.method} ${request.url}`);
      const { notes, ...rest } = JSON.parse(body) as { notes: Sent[] };
      if (Object.keys(rest).length || notes.length > 40) this.problems.push(`a call with ${notes.length} notes and ${Object.keys(rest)}`);
      for (const note of notes) {
        if (Object.keys(note).some((field) => !["handle", "sealed", "collapse"].includes(field))) this.problems.push(`a note with ${Object.keys(note)}`);
      }
      this.calls.push(notes);
      response.writeHead(this.status, { "content-type": "application/json" });
      const handles = notes.map((note) => note.handle);
      const failed = handles.filter((handle) => this.failed.has(handle)).map((handle) => ({ handle, reason: this.failed.get(handle) }));
      response.end(JSON.stringify(this.status === 200 ? { gone: handles.filter((handle) => this.gone.has(handle)), failed } : { message: "No" }));
    });
  });

  async start() {
    await new Promise<void>((resolve) => this.server.listen(0, "127.0.0.1", resolve));
  }

  stop() {
    this.server.closeAllConnections();
    return new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  get url() {
    return `http://127.0.0.1:${(this.server.address() as AddressInfo).port}`;
  }

  /** The next call's notes. Each event the network notifies is one call here. */
  async next(): Promise<Sent[]> {
    for (let waited = 0; !this.calls.length; waited += 20) {
      if (waited > 5000) throw new Error("No notes reached the relay");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return this.calls.shift()!;
  }

  /** Nothing reaches the relay for a moment. */
  async quiet() {
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.deepEqual(this.calls.splice(0), [], "nothing should have reached the relay");
  }
}

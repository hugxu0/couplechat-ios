import { searchMemory, visibleMemoryScopes } from "./store";

export async function listDajuInstructionsForRequester(
  storedChannel: string,
  requesterUsername: string,
  limit = 20,
) {
  const requester = requesterUsername.trim();
  if (!requester) return [];
  return searchMemory({
    query: "",
    layers: ["fact"],
    scopes: visibleMemoryScopes(storedChannel),
    perspectives: ["daju"],
    kinds: ["instruction"],
    subjects: [requester],
    subjectMode: "related",
    sort: "importance",
    limit: Math.max(1, Math.min(20, limit)),
  });
}

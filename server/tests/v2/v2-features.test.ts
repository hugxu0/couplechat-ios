import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("V2 transcription, albums, calendar and pet are durable and couple-isolated", async () => {
  const previousTranscription = {
    provider: process.env.TRANSCRIPTION_PROVIDER,
    baseUrl: process.env.TRANSCRIPTION_BASE_URL,
    apiKey: process.env.TRANSCRIPTION_API_KEY,
    model: process.env.TRANSCRIPTION_MODEL,
  };
  process.env.TRANSCRIPTION_PROVIDER = "fake-test";
  process.env.TRANSCRIPTION_BASE_URL = "http://127.0.0.1:1/v1";
  process.env.TRANSCRIPTION_API_KEY = "fake-test-key";
  process.env.TRANSCRIPTION_MODEL = "fake-test-model";
  try {
    await withTestDatabase(async () => {
      const { buildApp } = await import("../../src/app");
      const { all, get, run } = await import("../../src/db");
      const { verifyActiveToken } = await import("../../src/auth/token");
      const { createMessage, fetchMessages, recallMessage, searchMessages } = await import("../../src/chat/messageService");
      const { runTranscriptWorkerOnce } = await import("../../src/transcription/service");
      const { createTranscriptScheduler } = await import("../../src/transcription/scheduler");
      const app = await buildApp();
      const auth = (token: string) => ({ authorization: `Bearer ${token}` });
      const device = (name: string) => ({
        installationId: `installation-${name}`,
        platform: "ios",
        deviceName: name,
        appVersion: "0.3.0",
        buildNumber: "3",
        locale: "zh_CN",
        timezone: "Asia/Shanghai",
      });
      const register = async (username: string) => {
        const response = await app.inject({
          method: "POST",
          url: "/api/v2/register",
          payload: { username, displayName: username.toUpperCase(), password: "password-123", device: device(username) },
        });
        assert.equal(response.statusCode, 201, response.body);
        return response.json().token as string;
      };
      const pair = async (ownerToken: string, memberToken: string, name: string) => {
        const created = await app.inject({
          method: "POST", url: "/api/v2/couples", headers: auth(ownerToken), payload: { name },
        });
        assert.equal(created.statusCode, 201, created.body);
        const invitation = created.json().invite.code as string;
        const joined = await app.inject({
          method: "POST", url: "/api/v2/couples/join", headers: auth(memberToken), payload: { code: invitation },
        });
        assert.equal(joined.statusCode, 200, joined.body);
      };
      const aliceToken = await register("alice");
      const bobToken = await register("bob_user");
      const carolToken = await register("carol");
      const daveToken = await register("dave_user");
      await pair(aliceToken, bobToken, "Alice + Bob");
      await pair(carolToken, daveToken, "Carol + Dave");
      const alice = await verifyActiveToken(aliceToken);
      const bob = await verifyActiveToken(bobToken);
      assert.ok(alice?.coupleId && bob?.coupleId);

      const insertUpload = async (id: string, owner: string, mimeType: string) => {
        await run(
          `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'message')`,
          [id, owner, `D:/nonexistent/${id}`, `http://example.test/media/${id}`, mimeType, 128, Date.now()],
        );
      };

      // Transcription: queued -> processing -> completed, correction is returned and searchable.
      await insertUpload("up_voice_success_001", "alice", "audio/m4a");
      const voice = await createMessage(alice!, {
        channel: "couple", type: "voice", text: "", uploadId: "up_voice_success_001", clientId: "voice-success",
      });
      assert.equal(voice.transcript?.status, "pending");
      const scheduler = createTranscriptScheduler({
        name: "fake-test",
        transcribe: async () => ({ text: "我们周末一起去公园", language: "zh" }),
      }, 60_000);
      assert.equal(await scheduler.tick(), true);
      scheduler.stop();
      const transcriptResponse = await app.inject({
        method: "GET", url: `/api/v2/messages/${voice.id}/transcript`, headers: auth(bobToken),
      });
      assert.equal(transcriptResponse.statusCode, 200, transcriptResponse.body);
      const completed = transcriptResponse.json().transcript as { status: string; version: number; text: string };
      assert.equal(completed.status, "completed");
      assert.equal(completed.text, "我们周末一起去公园");
      assert.equal((await fetchMessages(bob!, { channel: "couple" }))[0].transcript?.text, completed.text);
      assert.deepEqual((await searchMessages(bob!, "couple", "公园")).map((item) => item.id), [voice.id]);
      const foreignTranscript = await app.inject({
        method: "GET", url: `/api/v2/messages/${voice.id}/transcript`, headers: auth(carolToken),
      });
      assert.equal(foreignTranscript.statusCode, 404);
      const corrected = await app.inject({
        method: "PATCH",
        url: `/api/v2/messages/${voice.id}/transcript`,
        headers: auth(bobToken),
        payload: { text: "我们周六一起去公园", baseVersion: completed.version },
      });
      assert.equal(corrected.statusCode, 200, corrected.body);
      assert.equal(corrected.json().transcript.corrected, true);
      assert.equal((await searchMessages(alice!, "couple", "周六"))[0]?.id, voice.id);
      assert.equal((await searchMessages(alice!, "couple", "周末")).length, 0, "corrected text replaces raw search text");

      // Failed jobs are explicitly retryable and a provider-neutral scheduler can complete them.
      await insertUpload("up_voice_retry_0002", "alice", "audio/m4a");
      const retryVoice = await createMessage(alice!, {
        channel: "couple", type: "voice", text: "", uploadId: "up_voice_retry_0002", clientId: "voice-retry",
      });
      assert.equal(await runTranscriptWorkerOnce({
        name: "fake-test",
        transcribe: async () => { throw new Error("temporary_provider_failure"); },
      }), true);
      assert.equal((await get<{ status: string }>(
        "SELECT status FROM message_transcripts WHERE message_id = ?", [retryVoice.id],
      ))?.status, "failed");
      const retried = await app.inject({
        method: "POST", url: `/api/v2/messages/${retryVoice.id}/transcript/retry`, headers: auth(aliceToken),
      });
      assert.equal(retried.statusCode, 200, retried.body);
      assert.equal(retried.json().transcript.status, "pending");
      assert.equal(await runTranscriptWorkerOnce({
        name: "fake-test",
        transcribe: async () => ({ text: "重试成功" }),
      }), true);
      assert.equal((await get<{ status: string }>(
        "SELECT status FROM message_transcripts WHERE message_id = ?", [retryVoice.id],
      ))?.status, "completed");

      // 升级前的历史语音没有 transcript 行，首次手动重试也必须能补建任务。
      await insertUpload("up_voice_legacy_0003", "alice", "audio/m4a");
      const legacyVoice = await createMessage(alice!, {
        channel: "couple", type: "voice", text: "", uploadId: "up_voice_legacy_0003", clientId: "voice-legacy",
      });
      await run("DELETE FROM transcript_jobs WHERE message_id = ?", [legacyVoice.id]);
      await run("DELETE FROM message_transcripts WHERE message_id = ?", [legacyVoice.id]);
      const legacyRetry = await app.inject({
        method: "POST", url: `/api/v2/messages/${legacyVoice.id}/transcript/retry`, headers: auth(bobToken),
      });
      assert.equal(legacyRetry.statusCode, 200, legacyRetry.body);
      assert.equal(legacyRetry.json().transcript.status, "pending");
      assert.equal(await runTranscriptWorkerOnce({
        name: "fake-test",
        transcribe: async () => ({ text: "历史语音也成功了" }),
      }), true);
      assert.equal((await get<{ text: string }>(
        "SELECT text FROM message_transcripts WHERE message_id = ?", [legacyVoice.id],
      ))?.text, "历史语音也成功了");

      delete process.env.TRANSCRIPTION_BASE_URL;
      delete process.env.TRANSCRIPTION_API_KEY;
      delete process.env.TRANSCRIPTION_MODEL;
      await insertUpload("up_voice_unavailable", "alice", "audio/m4a");
      const unavailableVoice = await createMessage(alice!, {
        channel: "couple", type: "voice", text: "", uploadId: "up_voice_unavailable", clientId: "voice-unavailable",
      });
      assert.equal(unavailableVoice.transcript?.status, "unavailable");
      const unavailableRetry = await app.inject({
        method: "POST", url: `/api/v2/messages/${unavailableVoice.id}/transcript/retry`, headers: auth(aliceToken),
      });
      assert.equal(unavailableRetry.statusCode, 200);
      assert.equal(unavailableRetry.json().transcript.status, "unavailable");
      process.env.TRANSCRIPTION_BASE_URL = "http://127.0.0.1:1/v1";
      process.env.TRANSCRIPTION_API_KEY = "fake-test-key";
      process.env.TRANSCRIPTION_MODEL = "fake-test-model";

      assert.equal((await recallMessage(alice!, voice.id))?.deleted, true);
      assert.equal(await get("SELECT 1 AS found FROM message_transcripts WHERE message_id = ?", [voice.id]), undefined);
      assert.equal(await get("SELECT 1 AS found FROM transcript_jobs WHERE message_id = ?", [voice.id]), undefined);

      // Albums: import from this couple's chat, de-duplicate, note, cover URL and leap-day On This Day.
      await insertUpload("up_album_photo_0003", "alice", "image/jpeg");
      const photo = await createMessage(alice!, {
        channel: "couple", type: "image", text: "旧照片", uploadId: "up_album_photo_0003", clientId: "album-photo",
      });
      const albumCreated = await app.inject({
        method: "POST", url: "/api/v2/albums", headers: auth(aliceToken), payload: { title: "一起走过", summary: "共同相册" },
      });
      assert.equal(albumCreated.statusCode, 201, albumCreated.body);
      const albumId = albumCreated.json().album.id as string;
      const addPhoto = async () => app.inject({
        method: "POST",
        url: `/api/v2/albums/${albumId}/items/from-message`,
        headers: auth(aliceToken),
        payload: { messageId: photo.id },
      });
      const firstAdd = await addPhoto();
      assert.equal(firstAdd.statusCode, 201, firstAdd.body);
      assert.equal(firstAdd.json().added.length, 1);
      const duplicateAdd = await addPhoto();
      assert.equal(duplicateAdd.statusCode, 201, duplicateAdd.body);
      assert.equal(duplicateAdd.json().added.length, 0);
      const assetId = firstAdd.json().added[0].asset.id as string;
      const albumList = await app.inject({ method: "GET", url: "/api/v2/albums", headers: auth(bobToken) });
      assert.equal(albumList.json().albums[0].coverURL, `http://example.test/media/up_album_photo_0003`);
      const note = await app.inject({
        method: "PATCH", url: `/api/v2/media-assets/${assetId}/note`, headers: auth(bobToken), payload: { text: "那天风很温柔" },
      });
      assert.equal(note.statusCode, 200, note.body);
      await run("UPDATE media_assets SET taken_at = ? WHERE id = ?", [Date.parse("2024-02-29T04:00:00Z"), assetId]);
      const anniversary = await app.inject({
        method: "GET",
        url: "/api/v2/media/on-this-day?timezone=Asia%2FShanghai&date=2025-02-28",
        headers: auth(bobToken),
      });
      assert.equal(anniversary.statusCode, 200, anniversary.body);
      assert.equal(anniversary.json().assets[0].id, assetId, "Feb 29 appears on Feb 28 in a non-leap year");
      assert.equal(anniversary.json().assets[0].note.text, "那天风很温柔");
      const foreignAlbum = await app.inject({
        method: "GET", url: `/api/v2/albums/${albumId}/items`, headers: auth(carolToken),
      });
      assert.equal(foreignAlbum.statusCode, 404);
      assert.equal((await recallMessage(alice!, photo.id))?.deleted, true);
      assert.equal(await get("SELECT 1 AS found FROM media_assets WHERE id = ?", [assetId]), undefined);
      assert.equal(await get("SELECT 1 AS found FROM media_notes WHERE asset_id = ?", [assetId]), undefined);
      const emptiedAlbum = await app.inject({
        method: "GET", url: `/api/v2/albums/${albumId}/items`, headers: auth(bobToken),
      });
      assert.equal(emptiedAlbum.statusCode, 200, emptiedAlbum.body);
      assert.equal(emptiedAlbum.json().items.length, 0);
      assert.equal(emptiedAlbum.json().album.coverURL, undefined);
      const deletedAlbum = await app.inject({
        method: "DELETE", url: `/api/v2/albums/${albumId}`, headers: auth(aliceToken),
        payload: { baseVersion: emptiedAlbum.json().album.version },
      });
      assert.equal(deletedAlbum.statusCode, 200, deletedAlbum.body);

      // Calendar: shared is visible to both, private only to creator, all-day/timezone and versions are strict.
      const dayStart = Date.parse("2026-07-20T16:00:00Z"); // 2026-07-21 00:00 Asia/Shanghai
      const dayEnd = Date.parse("2026-07-21T16:00:00Z");
      const sharedEvent = await app.inject({
        method: "POST", url: "/api/v2/calendar/events", headers: auth(aliceToken),
        payload: { scope: "shared", title: "一起看展", notes: "下午出发", startAt: dayStart,
          endAt: dayEnd, timezone: "Asia/Shanghai", allDay: true },
      });
      assert.equal(sharedEvent.statusCode, 201, sharedEvent.body);
      assert.equal(sharedEvent.json().event.participants.length, 2);
      const sharedEventId = sharedEvent.json().event.id as string;
      const privateEvent = await app.inject({
        method: "POST", url: "/api/v2/calendar/events", headers: auth(aliceToken),
        payload: { scope: "private", title: "准备惊喜", notes: "", startAt: dayStart + 3_600_000,
          endAt: dayStart + 7_200_000, timezone: "Asia/Shanghai", allDay: false },
      });
      assert.equal(privateEvent.statusCode, 201, privateEvent.body);
      const bobMonth = await app.inject({
        method: "GET", url: "/api/v2/calendar/events?view=month&month=2026-07&timezone=Asia%2FShanghai", headers: auth(bobToken),
      });
      assert.deepEqual(bobMonth.json().events.map((event: { title: string }) => event.title), ["一起看展"]);
      const aliceAgenda = await app.inject({
        method: "GET", url: "/api/v2/calendar/events?view=agenda&limit=10", headers: auth(aliceToken),
      });
      assert.deepEqual(new Set(aliceAgenda.json().events.map((event: { title: string }) => event.title)),
        new Set(["一起看展", "准备惊喜"]));
      const invalidAllDay = await app.inject({
        method: "POST", url: "/api/v2/calendar/events", headers: auth(aliceToken),
        payload: { scope: "shared", title: "时间不齐", notes: "", startAt: dayStart + 3_600_000,
          endAt: dayEnd, timezone: "Asia/Shanghai", allDay: true },
      });
      assert.equal(invalidAllDay.statusCode, 400);
      const staleCalendar = await app.inject({
        method: "PATCH", url: `/api/v2/calendar/events/${sharedEventId}`, headers: auth(bobToken),
        payload: { title: "冲突更新", baseVersion: 9 },
      });
      assert.equal(staleCalendar.statusCode, 409);
      const updatedCalendar = await app.inject({
        method: "PATCH", url: `/api/v2/calendar/events/${sharedEventId}`, headers: auth(bobToken),
        payload: { title: "一起看新展", baseVersion: 0 },
      });
      assert.equal(updatedCalendar.statusCode, 200, updatedCalendar.body);
      const completedCalendar = await app.inject({
        method: "POST", url: `/api/v2/calendar/events/${sharedEventId}/complete`, headers: auth(aliceToken),
        payload: { completed: true, baseVersion: 1 },
      });
      assert.equal(completedCalendar.statusCode, 200, completedCalendar.body);
      assert.equal(completedCalendar.json().event.status, "completed");
      const deletedCalendar = await app.inject({
        method: "DELETE", url: `/api/v2/calendar/events/${sharedEventId}`, headers: auth(bobToken),
        payload: { baseVersion: completedCalendar.json().event.version },
      });
      assert.equal(deletedCalendar.statusCode, 200, deletedCalendar.body);

      // Pet: one authoritative couple pet, asynchronous two-person settlement, idempotency and versioned scene.
      const alicePetResponse = await app.inject({ method: "GET", url: "/api/v2/pet", headers: auth(aliceToken) });
      const bobPetResponse = await app.inject({ method: "GET", url: "/api/v2/pet", headers: auth(bobToken) });
      assert.equal(alicePetResponse.statusCode, 200, alicePetResponse.body);
      const initialPet = alicePetResponse.json().pet as any;
      assert.equal(initialPet.id, bobPetResponse.json().pet.id);
      assert.equal(initialPet.name, "大橘");
      assert.equal(initialPet.inventory.length, 1);
      const aliceAnswer = await app.inject({
        method: "POST", url: "/api/v2/pet/today/responses", headers: auth(aliceToken),
        payload: { promptId: initialPet.today.id, text: "一起散步", idempotencyKey: "answer-alice-1", baseVersion: 0 },
      });
      assert.equal(aliceAnswer.statusCode, 200, aliceAnswer.body);
      assert.equal(aliceAnswer.json().pet.version, 0, "first response keeps the shared baseVersion usable");
      const bobAnswer = await app.inject({
        method: "POST", url: "/api/v2/pet/today/responses", headers: auth(bobToken),
        payload: { promptId: initialPet.today.id, text: "去吃甜品", idempotencyKey: "answer-bob-1", baseVersion: 0 },
      });
      assert.equal(bobAnswer.statusCode, 200, bobAnswer.body);
      const settledPet = bobAnswer.json().pet as any;
      assert.equal(settledPet.today.status, "settled");
      assert.equal(settledPet.today.responses.length, 2);
      assert.equal(settledPet.inventory.length, 2);
      assert.equal(settledPet.moments.length, 1);
      const bobAnswerRetry = await app.inject({
        method: "POST", url: "/api/v2/pet/today/responses", headers: auth(bobToken),
        payload: { promptId: initialPet.today.id, text: "ignored retry body", idempotencyKey: "answer-bob-1", baseVersion: 0 },
      });
      assert.equal(bobAnswerRetry.statusCode, 200, bobAnswerRetry.body);
      assert.equal((await get<{ count: number }>("SELECT COUNT(*) AS count FROM pet_moments"))?.count, 1);
      const interaction = await app.inject({
        method: "POST", url: "/api/v2/pet/interactions", headers: auth(aliceToken),
        payload: { kind: "high_five", idempotencyKey: "interaction-1", baseVersion: settledPet.version },
      });
      assert.equal(interaction.statusCode, 200, interaction.body);
      assert.equal(interaction.json().pet.latestInteraction.kind, "high_five");
      const interactionRetry = await app.inject({
        method: "POST", url: "/api/v2/pet/interactions", headers: auth(aliceToken),
        payload: { kind: "high_five", idempotencyKey: "interaction-1", baseVersion: settledPet.version },
      });
      assert.equal(interactionRetry.statusCode, 200, interactionRetry.body);
      assert.equal((await get<{ count: number }>("SELECT COUNT(*) AS count FROM pet_actions"))?.count, 1);
      const interactionPet = interaction.json().pet as any;
      const rewardItemId = interactionPet.inventory.find((item: any) => item.kind === "keepsake").id as string;
      assert.equal((await get<{ coins: number }>("SELECT coins FROM pets WHERE id = ?", [interactionPet.id]))?.coins, 0);
      const scene = await app.inject({
        method: "PATCH", url: "/api/v2/pet/scene", headers: auth(bobToken),
        payload: { placedItemIds: [rewardItemId], baseVersion: interactionPet.version },
      });
      assert.equal(scene.statusCode, 200, scene.body);
      assert.deepEqual(scene.json().pet.scene.placedItemIds, [rewardItemId]);
      const staleRename = await app.inject({
        method: "PATCH", url: "/api/v2/pet/name", headers: auth(aliceToken),
        payload: { name: "橘宝", baseVersion: interactionPet.version },
      });
      assert.equal(staleRename.statusCode, 409);
      const rename = await app.inject({
        method: "PATCH", url: "/api/v2/pet/name", headers: auth(aliceToken),
        payload: { name: "橘宝", baseVersion: scene.json().pet.version },
      });
      assert.equal(rename.statusCode, 200, rename.body);
      assert.equal(rename.json().pet.name, "橘宝");
      const carolPet = await app.inject({ method: "GET", url: "/api/v2/pet", headers: auth(carolToken) });
      assert.notEqual(carolPet.json().pet.id, initialPet.id);

      const syncRows = await all<{ entity_type: string }>(
        "SELECT entity_type FROM sync_events WHERE couple_id = ?", [alice!.coupleId],
      );
      const synced = new Set(syncRows.map((row) => row.entity_type));
      for (const entity of ["message_transcript", "album", "media_note", "calendar_event", "pet"]) {
        assert.ok(synced.has(entity), `sync event missing for ${entity}`);
      }
      await app.close();
    });
  } finally {
    const restore = (name: string, value: string | undefined) => {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    };
    restore("TRANSCRIPTION_PROVIDER", previousTranscription.provider);
    restore("TRANSCRIPTION_BASE_URL", previousTranscription.baseUrl);
    restore("TRANSCRIPTION_API_KEY", previousTranscription.apiKey);
    restore("TRANSCRIPTION_MODEL", previousTranscription.model);
  }
});

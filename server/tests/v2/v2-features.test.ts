import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("V2 transcription, albums, calendar and pet are durable for the fixed couple", async () => {
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
      const { ensureFixedConversations, ensureFixedCouple } = await import("../../src/auth/accounts");
      const { hashPassword } = await import("../../src/auth/password");
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
      const createFixedAccount = async (username: string, displayName: string) => {
        const now = Date.now();
        await run(
          `INSERT INTO accounts
           (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
           VALUES (?, ?, ?, ?, '', 'active', 0, ?, ?)`,
          [`acc_legacy_${username}`, username, displayName, hashPassword("password-123"), now, now],
        );
      };
      await createFixedAccount("xu", "小旭");
      await createFixedAccount("si", "小偲");
      await ensureFixedCouple();
      await ensureFixedConversations();
      const login = async (username: string) => {
        const response = await app.inject({
          method: "POST",
          url: "/api/v2/login",
          payload: { username, password: "password-123", device: device(username) },
        });
        assert.equal(response.statusCode, 200, response.body);
        return response.json().token as string;
      };
      const aliceToken = await login("xu");
      const bobToken = await login("si");
      const alice = await verifyActiveToken(aliceToken);
      const bob = await verifyActiveToken(bobToken);
      assert.ok(alice?.coupleId && bob?.coupleId);

      const insertUpload = async (id: string, owner: string, mimeType: string, purpose = "message") => {
        await run(
          `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          [id, owner, `D:/nonexistent/${id}`, `http://example.test/media/${id}`, mimeType, 128, Date.now(), purpose],
        );
      };

      // Transcription: queued -> processing -> completed and searchable.
      await insertUpload("up_voice_success_001", "xu", "audio/m4a");
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
      const completed = transcriptResponse.json().transcript as { status: string; text: string };
      assert.equal(completed.status, "completed");
      assert.equal(completed.text, "我们周末一起去公园");
      assert.equal((await fetchMessages(bob!, { channel: "couple" }))[0].transcript?.text, completed.text);
      assert.deepEqual((await searchMessages(bob!, "couple", "公园")).map((item) => item.id), [voice.id]);
      assert.equal((await app.inject({
        method: "PATCH", url: `/api/v2/messages/${voice.id}/transcript`, headers: auth(bobToken),
      })).statusCode, 404, "transcript correction is not a product feature");

      // Failed jobs are explicitly retryable and a provider-neutral scheduler can complete them.
      await insertUpload("up_voice_retry_0002", "xu", "audio/m4a");
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
      await insertUpload("up_voice_legacy_0003", "xu", "audio/m4a");
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
      await insertUpload("up_voice_unavailable", "xu", "audio/m4a");
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

      const statsResponse = await app.inject({
        method: "GET", url: "/api/v2/chat/stats", headers: auth(aliceToken),
      });
      assert.equal(statsResponse.statusCode, 200, statsResponse.body);
      const stats = statsResponse.json() as {
        days: Array<{ bucket: string; sender: string; count: number }>;
      };
      assert.ok(stats.days.some((row) => row.sender === "xu" && row.count >= 1));

      assert.equal((await recallMessage(alice!, voice.id))?.deleted, true);
      assert.equal(await get("SELECT 1 AS found FROM message_transcripts WHERE message_id = ?", [voice.id]), undefined);
      assert.equal(await get("SELECT 1 AS found FROM transcript_jobs WHERE message_id = ?", [voice.id]), undefined);

      // Albums: import from this couple's chat, de-duplicate, note, cover URL and leap-day On This Day.
      await insertUpload("up_album_photo_0003", "xu", "image/jpeg");
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
      await insertUpload("up_album_direct_0004", "xu", "video/mp4", "album");
      const directAdd = await app.inject({
        method: "POST",
        url: `/api/v2/albums/${albumId}/items/from-upload`,
        headers: auth(aliceToken),
        payload: {
          uploadId: "up_album_direct_0004",
          takenAt: Date.parse("2025-07-12T08:00:00Z"),
          postId: "post-summer-trip",
        },
      });
      assert.equal(directAdd.statusCode, 201, directAdd.body);
      assert.equal(directAdd.json().added[0].asset.kind, "video");
      assert.equal(directAdd.json().added[0].asset.sourceMessageId, undefined);
      assert.equal(directAdd.json().added[0].postId, "post-summer-trip");
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
      assert.equal((await recallMessage(alice!, photo.id))?.deleted, true);
      assert.equal(await get("SELECT 1 AS found FROM media_assets WHERE id = ?", [assetId]), undefined);
      assert.equal(await get("SELECT 1 AS found FROM media_notes WHERE asset_id = ?", [assetId]), undefined);
      const emptiedAlbum = await app.inject({
        method: "GET", url: `/api/v2/albums/${albumId}/items`, headers: auth(bobToken),
      });
      assert.equal(emptiedAlbum.statusCode, 200, emptiedAlbum.body);
      assert.equal(emptiedAlbum.json().items.length, 1, "direct uploads survive recalling an unrelated chat message");
      assert.equal(emptiedAlbum.json().items[0].postId, "post-summer-trip");
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

      // Pet: one authoritative couple pet with five durable, versioned interactions.
      const alicePetResponse = await app.inject({ method: "GET", url: "/api/v2/pet", headers: auth(aliceToken) });
      const bobPetResponse = await app.inject({ method: "GET", url: "/api/v2/pet", headers: auth(bobToken) });
      assert.equal(alicePetResponse.statusCode, 200, alicePetResponse.body);
      const initialPet = alicePetResponse.json().pet as any;
      assert.equal(initialPet.id, bobPetResponse.json().pet.id);
      assert.equal(initialPet.satiety, 80);
      assert.equal(initialPet.cleanliness, 80);
      assert.equal(initialPet.energy, 100);
      assert.equal(initialPet.mood, 80);
      for (const removedPath of ["/api/v2/pet/today", "/api/v2/pet/scene", "/api/v2/pet/name"]) {
        assert.equal((await app.inject({ method: "GET", url: removedPath, headers: auth(aliceToken) })).statusCode, 404);
      }
      const interaction = await app.inject({
        method: "POST", url: "/api/v2/pet/interactions", headers: auth(aliceToken),
        payload: { kind: "stroke", idempotencyKey: "interaction-1", baseVersion: initialPet.version },
      });
      assert.equal(interaction.statusCode, 200, interaction.body);
      assert.equal(interaction.json().pet.latestInteraction.kind, "stroke");
      assert.equal(interaction.json().pet.mood, 86);
      assert.equal(interaction.json().pet.experience, 1);
      const interactionRetry = await app.inject({
        method: "POST", url: "/api/v2/pet/interactions", headers: auth(aliceToken),
        payload: { kind: "stroke", idempotencyKey: "interaction-1", baseVersion: initialPet.version },
      });
      assert.equal(interactionRetry.statusCode, 200, interactionRetry.body);
      assert.equal((await get<{ count: number }>("SELECT COUNT(*) AS count FROM pet_actions"))?.count, 1);
      const interactionCooldown = await app.inject({
        method: "POST", url: "/api/v2/pet/interactions", headers: auth(bobToken),
        payload: {
          kind: "stroke",
          idempotencyKey: "interaction-2",
          baseVersion: interaction.json().pet.version,
        },
      });
      assert.equal(interactionCooldown.statusCode, 429, interactionCooldown.body);
      assert.equal(interactionCooldown.json().error, "pet_interaction_cooldown");
      assert.ok(interactionCooldown.json().availableAt > Date.now());
      assert.equal((await get<{ count: number }>("SELECT COUNT(*) AS count FROM pet_actions"))?.count, 1);
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

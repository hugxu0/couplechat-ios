import type { AuthUser, ClientMessage } from "../types";

const fallbackReplies = [
  "喵，我在。你慢慢说，我会认真听。",
  "先抱一下。这个小空间里，你不用急着把话说完。",
  "大橘收到啦。等真正的模型接上，我就能更聪明地陪你聊天。",
  "我先把这句话放在爪子下面保管好。",
];

export async function generateAiReply(_user: AuthUser, message: ClientMessage) {
  const text = message.text.trim();
  if (text.length === 0) return fallbackReplies[0];

  const index = Math.abs([...text].reduce((sum, char) => sum + char.charCodeAt(0), 0)) % fallbackReplies.length;
  return fallbackReplies[index];
}

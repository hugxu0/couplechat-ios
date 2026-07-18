import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const THUMBNAIL_MAX_EDGE = 720;
const THUMBNAIL_MAX_INPUT_PIXELS = 80_000_000;
const THUMBNAIL_CONCURRENCY = 2;
const THUMBNAIL_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/heif",
]);
let activeThumbnailJobs = 0;
const thumbnailWaiters: Array<() => void> = [];

function acquireThumbnailSlot(): Promise<void> {
  if (activeThumbnailJobs < THUMBNAIL_CONCURRENCY) {
    activeThumbnailJobs += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => thumbnailWaiters.push(resolve));
}

function releaseThumbnailSlot() {
  const next = thumbnailWaiters.shift();
  if (next) {
    next();
  } else {
    activeThumbnailJobs -= 1;
  }
}

export function thumbnailPathFor(sourcePath: string): string {
  const parsed = path.parse(sourcePath);
  return path.join(parsed.dir, `${parsed.name}.thumbnail.jpg`);
}

/**
 * 上传时生成静态聊天预览。动图继续由客户端读取原资源，避免气泡从动画
 * 退化成首帧；不支持的 HEIF 编解码也只跳过缩略图，不影响原图上传。
 */
export async function createImageThumbnail(
  sourcePath: string,
  destinationPath: string,
  mimeType: string,
): Promise<boolean> {
  if (!THUMBNAIL_MIME_TYPES.has(mimeType)) return false;
  await acquireThumbnailSlot();
  try {
    const image = sharp(sourcePath, {
      failOn: "error",
      limitInputPixels: THUMBNAIL_MAX_INPUT_PIXELS,
    });
    const metadata = await image.metadata();
    if ((mimeType === "image/png" || mimeType === "image/webp") && (metadata.pages ?? 1) > 1) {
      return false;
    }
    await image
      .rotate()
      .resize({
        width: THUMBNAIL_MAX_EDGE,
        height: THUMBNAIL_MAX_EDGE,
        fit: "inside",
        withoutEnlargement: true,
      })
      .jpeg({
        quality: 78,
        progressive: true,
        chromaSubsampling: "4:2:0",
      })
      .toFile(destinationPath);
    return true;
  } catch {
    await fs.rm(destinationPath, { force: true }).catch(() => undefined);
    return false;
  } finally {
    releaseThumbnailSlot();
  }
}

export async function validateClientThumbnail(data: Buffer): Promise<boolean> {
  try {
    const metadata = await sharp(data, {
      failOn: "error",
      limitInputPixels: THUMBNAIL_MAX_EDGE * THUMBNAIL_MAX_EDGE,
    }).metadata();
    return metadata.format === "jpeg" &&
      (metadata.pages ?? 1) === 1 &&
      typeof metadata.width === "number" &&
      typeof metadata.height === "number" &&
      metadata.width > 0 &&
      metadata.height > 0 &&
      metadata.width <= THUMBNAIL_MAX_EDGE &&
      metadata.height <= THUMBNAIL_MAX_EDGE;
  } catch {
    return false;
  }
}

export async function removeUploadArtifacts(sourcePath: string): Promise<void> {
  await Promise.all([
    fs.rm(sourcePath, { force: true }),
    fs.rm(thumbnailPathFor(sourcePath), { force: true }),
  ]);
}

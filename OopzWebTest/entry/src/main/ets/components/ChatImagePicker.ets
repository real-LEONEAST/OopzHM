import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { MAX_CHAT_IMAGE_BYTES } from '../oopz/OopzSession';
import type { OopzChatImage } from '../oopz/OopzSession';

const MAX_IMAGE_EDGE = 2048;
const MAX_SOURCE_BYTES = 32 * 1024 * 1024;
const MAX_SOURCE_PIXELS = 64 * 1024 * 1024;

export interface ChatImageDraft {
  name: string;
  path: string;
  previewUri: string;
}

export interface ChatImageSelection {
  preview: ChatImageDraft;
  image: OopzChatImage;
}

async function selectImageUri(context: common.UIAbilityContext, desktop: boolean): Promise<string> {
  if (desktop) {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FILE;
    options.fileSuffixFilters = ['图片|.jpg,.jpeg,.png,.webp,.heic,.heif,.bmp,.gif'];
    return (await new picker.DocumentViewPicker(context).select(options))[0] ?? '';
  }
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 1;
  options.isPhotoTakingSupported = false;
  const result = await new photoAccessHelper.PhotoViewPicker().select(options);
  return result.photoUris[0] ?? '';
}

async function applyImageOrientation(source: image.ImageSource, pixels: image.PixelMap): Promise<void> {
  const orientation = await source.getImageProperty(image.PropertyKey.ORIENTATION).catch(() => '');
  if (orientation === 'Top-right' || orientation === 'Left-top' || orientation === 'Right-bottom') {
    await pixels.flip(true, false);
  } else if (orientation === 'Bottom-left') {
    await pixels.flip(false, true);
  }
  if (orientation === 'Right-top' || orientation === 'Right-bottom') {
    await pixels.rotate(90);
  } else if (orientation === 'Left-top' || orientation === 'Left-bottom') {
    await pixels.rotate(270);
  } else if (orientation === 'Bottom-right') {
    await pixels.rotate(180);
  }
}

async function prepareImage(uri: string): Promise<OopzChatImage> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  let source: image.ImageSource | undefined;
  let pixels: image.PixelMap | undefined;
  let encoder: image.ImagePacker | undefined;
  try {
    if ((await fileIo.stat(file.fd)).size > MAX_SOURCE_BYTES) throw new Error('请选择 32 MB 以内的图片');
    source = image.createImageSource(file.fd);
    const info = await source.getImageInfo();
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0 || width * height > MAX_SOURCE_PIXELS) {
      throw new Error('图片尺寸过大或无法读取');
    }
    const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(width, height));
    pixels = await source.createPixelMap({
      desiredSize: { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) },
      editable: true
    });
    await applyImageOrientation(source, pixels);
    const encodedSize = (await pixels.getImageInfo()).size;
    encoder = image.createImagePacker();
    const bytes = await encoder.packToData(pixels, { format: 'image/webp', quality: 90, needsPackProperties: false });
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_CHAT_IMAGE_BYTES) {
      throw new Error('处理后的图片超过 8 MB，请选择较小的图片');
    }
    const name = file.name.replace(/\.[^.]+$/, '').trim();
    return { name: (name || '图片') + '.webp', width: encodedSize.width, height: encodedSize.height, bytes: bytes };
  } finally {
    await encoder?.release().catch(() => {});
    await pixels?.release().catch(() => {});
    await source?.release().catch(() => {});
    await fileIo.close(file).catch(() => {});
  }
}

export async function pickChatImage(context: common.UIAbilityContext,
  desktop: boolean): Promise<ChatImageSelection | undefined> {
  const uri = await selectImageUri(context, desktop);
  if (!uri) return undefined;
  const prepared = await prepareImage(uri);
  const cachePath = context.cacheDir + '/chat-image-' + util.generateRandomUUID() + '.webp';
  try {
    const file = await fileIo.open(cachePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    try {
      if (await fileIo.write(file.fd, prepared.bytes) !== prepared.bytes.byteLength) {
        throw new Error('图片预览暂存失败，请重试');
      }
    } finally {
      await fileIo.close(file);
    }
    return {
      preview: {
        name: prepared.name,
        path: cachePath,
        previewUri: fileUri.getUriFromPath(cachePath)
      },
      image: prepared
    };
  } catch (error) {
    await fileIo.unlink(cachePath).catch(() => {});
    throw new Error((error as Error).message || '图片预览暂存失败，请重试');
  }
}

export function discardChatImage(draft?: ChatImageDraft): void {
  if (draft) fileIo.unlink(draft.path).catch(() => {});
}

// ==UserScript==
// @name         Oopz 网页操作测试
// @namespace    oopz-harmony-local
// @version      0.3.0
// @description  测试读取 Oopz 网页控件、关闭活动弹窗和操作麦克风。
// @match        https://web.oopz.cn/*
// @noframes
// @grant        none
// @require      https://cdn.jsdelivr.net/npm/tesseract.js@6.0.1/dist/tesseract.min.js
// @run-at       document-end
// ==/UserScript==

(() => {
  'use strict';

  const panelId = 'oopz-web-test-panel';
  if (location.origin !== 'https://web.oopz.cn' || window.top !== window ||
      document.getElementById(panelId)) return;

  const buttonSelector = 'button, [role="button"], flt-semantics[flt-tappable]';
  const dialogSelector = 'dialog[open], [role="dialog"], [role="alertdialog"], [aria-modal="true"]';
  const promotionLabel = /活动|广告|推广|公告|限时福利/;
  const channelLabel = /^(?:当前语音频道|已加入语音频道|已连接到语音频道|语音已连接)\s*(?:[：:]\s*|\n)([^\n]{1,80})$/;
  const microphoneActions = new Map([
    ['关闭麦克风', 'on'], ['静音麦克风', 'on'], ['麦克风静音', 'on'],
    ['打开麦克风', 'muted'], ['开启麦克风', 'muted'], ['解除麦克风静音', 'muted'], ['取消麦克风静音', 'muted']
  ]);
  const activatedPlaceholders = new WeakSet();
  let popupAttempt;
  let muteAttempt;
  let microphonePoint;
  let calibrationLayer;
  let calibrationTimer;
  let popupMessage = '等待活动弹窗';
  let muteMessage = '';
  let visualJob;
  let visualChannel = '';
  let visualMessage = '';
  let visualPopupMessage = '';
  let offerTabCapture = false;

  const panel = document.createElement('section');
  panel.id = panelId;
  panel.setAttribute('aria-label', 'Oopz 网页操作测试');
  panel.style.cssText = 'position:fixed;z-index:2147483647;bottom:12px;right:12px;padding:12px;' +
    'width:min(280px,calc(100vw - 24px));box-sizing:border-box;background:#142331;color:#f3f8fb;' +
    'border:1px solid #486174;border-radius:10px;font:13px/1.55 system-ui;box-shadow:0 3px 18px #0005';
  const title = document.createElement('strong');
  title.textContent = 'Oopz 网页操作测试 v0.3.0';
  const output = document.createElement('div');
  output.dataset.oopzTestResult = 'true';
  output.style.whiteSpace = 'pre-line';
  const muteButton = document.createElement('button');
  muteButton.type = 'button';
  muteButton.disabled = true;
  muteButton.textContent = '测试麦克风';
  const buttonStyle = 'margin-top:8px;margin-right:6px;padding:5px 9px;border:0;border-radius:5px;font:inherit';
  muteButton.style.cssText = buttonStyle + ';color:#142331;background:#a5e6d8';
  const calibrateButton = document.createElement('button');
  calibrateButton.type = 'button';
  calibrateButton.textContent = '标定麦克风';
  calibrateButton.style.cssText = buttonStyle + ';color:#f3f8fb;background:#304658';
  const visualButton = document.createElement('button');
  visualButton.type = 'button';
  visualButton.style.cssText = calibrateButton.style.cssText;
  const tabCaptureButton = document.createElement('button');
  tabCaptureButton.type = 'button';
  tabCaptureButton.textContent = '使用当前标签画面';
  tabCaptureButton.style.cssText = calibrateButton.style.cssText;
  panel.append(title, output, visualButton, tabCaptureButton, calibrateButton, muteButton);
  document.body.append(panel);

  function flutterRoots() {
    const roots = [document];
    for (const root of roots) {
      for (const view of root.querySelectorAll('flutter-view, flt-glass-pane, flt-semantics-host')) {
        if (view.shadowRoot) roots.push(view.shadowRoot);
      }
    }
    return roots;
  }

  function readLabel(element) {
    const ariaLabel = element.getAttribute('aria-label');
    const labelledBy = element.getAttribute('aria-labelledby');
    const root = element.getRootNode();
    const referenced = labelledBy?.split(/\s+/).map(id => root.getElementById(id)?.textContent ?? '').join(' ');
    return (ariaLabel || referenced || element.getAttribute('title') || element.textContent || '')
      .replace(/\r/g, '').trim();
  }

  function isVisible(element) {
    if (element.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
    const style = getComputedStyle(element);
    if (style.visibility !== 'visible' || style.display === 'none') return false;
    const bounds = element.getBoundingClientRect();
    return bounds.width > 0 && bounds.height > 0 && bounds.bottom > 0 && bounds.right > 0 &&
      bounds.top < window.innerHeight && bounds.left < window.innerWidth;
  }

  function doesNotAcceptClicks(element) {
    return !isVisible(element) || Boolean(element.closest(':disabled, [aria-disabled="true"]'));
  }

  function findDismissButton(nodes) {
    const matches = nodes.filter(element =>
      element.matches(buttonSelector) && readLabel(element) === '不感兴趣' && !doesNotAcceptClicks(element));
    if (matches.length !== 1) return { found: matches.length > 0 };

    const button = matches[0];
    const dialog = button.closest(dialogSelector);
    if (!dialog || !isVisible(dialog)) return { found: true };
    const headings = [dialog, ...dialog.querySelectorAll('h1, h2, h3, [role="heading"], [aria-label]')];
    const isPromotion = headings.some(element => promotionLabel.test(readLabel(element).slice(0, 120)));
    return { found: true, ...(isPromotion ? { button, dialog } : {}) };
  }

  function readMicrophone(nodes) {
    const controls = nodes.flatMap(element => {
      if (!element.matches(buttonSelector)) return [];
      const state = microphoneActions.get(readLabel(element));
      return state && !doesNotAcceptClicks(element) ? [{ element, state }] : [];
    });
    return controls.length === 1 ? controls[0] : undefined;
  }

  function readChannel(nodes) {
    const names = new Set();
    for (const element of nodes) {
      if (!element.matches('flt-semantics[aria-label], [role="status"], [aria-current="true"]')) continue;
      const label = readLabel(element).match(channelLabel);
      if (label && isVisible(element)) names.add(label[1].trim());
    }
    return names.size === 1 ? [...names][0] : '';
  }

  function canvasTargetAt(x, y) {
    const hit = document.elementFromPoint(x, y);
    const view = hit?.closest('flutter-view');
    const glass = view?.querySelector('flt-glass-pane');
    const canvas = glass?.shadowRoot?.querySelector('canvas');
    if (!canvas) return;
    // Flutter's semantics layer is a sibling of the glass pane and can receive the real pointer event.
    const semantics = hit.closest('flt-semantics-host, flt-semantics');
    if (hit !== view && !glass.contains(hit) && !semantics) return;
    const rect = canvas.getBoundingClientRect();
    if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) return;

    const viewport = window.visualViewport;
    const layout = [window.innerWidth, window.innerHeight, window.devicePixelRatio,
      viewport?.scale, viewport?.offsetLeft, viewport?.offsetTop,
      rect.left, rect.top, rect.width, rect.height].join('/');
    const target = hit === glass ? glass.shadowRoot.elementFromPoint?.(x, y) || hit : hit;
    return { view, layout, target };
  }

  function calibratedTarget() {
    if (!microphonePoint) return;
    const { x, y, view, layout } = microphonePoint;
    const hit = canvasTargetAt(x, y);
    if (hit?.view === view && hit.layout === layout) return hit.target;
    if (!hit && view.isConnected) return;

    microphonePoint = undefined;
    muteMessage = '网页布局已变化，请重新标定';
  }

  function endCalibration() {
    clearTimeout(calibrationTimer);
    calibrationLayer?.remove();
    calibrationLayer = undefined;
    document.removeEventListener('keydown', cancelCalibration, true);
  }

  function cancelCalibration(event) {
    if (event.key !== 'Escape') return;
    event.stopPropagation();
    endCalibration();
    muteMessage = '已取消标定';
    update();
  }

  calibrateButton.addEventListener('click', event => {
    if (calibrationLayer || document.hidden || !event.isTrusted) return;
    microphonePoint = undefined;
    calibrationLayer = document.createElement('div');
    calibrationLayer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;cursor:crosshair';
    for (const type of ['pointerdown', 'pointerup']) {
      calibrationLayer.addEventListener(type, pointer => pointer.stopPropagation());
    }
    calibrationLayer.addEventListener('click', selection => {
      if (!selection.isTrusted) return;
      const { clientX: x, clientY: y } = selection;
      selection.stopPropagation();
      endCalibration();
      const hit = canvasTargetAt(x, y);
      if (hit) {
        microphonePoint = { x, y, view: hit.view, layout: hit.layout };
        muteMessage = `已保存位置（${Math.round(x)}, ${Math.round(y)}）。确认原图标可见后测试切换`;
      } else {
        muteMessage = '选点未落在 Oopz 画布。请点原网页左上角的麦克风图标';
      }
      update();
    });
    document.body.append(calibrationLayer);
    document.addEventListener('keydown', cancelCalibration, true);
    calibrationTimer = setTimeout(() => {
      endCalibration();
      muteMessage = '标定已超时';
      update();
    }, 30000);
    muteMessage = '请点原网页左上角的麦克风图标，Esc 取消';
    update();
  });

  function tapPoint(target, x, y) {
    const pointer = {
      bubbles: true, composed: true, cancelable: true, pointerId: 1, isPrimary: true,
      pointerType: 'mouse', button: 0, clientX: x, clientY: y
    };
    target.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1, pressure: 0.5 }));
    target.dispatchEvent(new PointerEvent('pointerup', { ...pointer, buttons: 0, pressure: 0 }));
  }

  function visualLayout() {
    return [innerWidth, innerHeight, devicePixelRatio, window.visualViewport?.scale].join('/');
  }

  function readCrop(job, crop, scale = 1) {
    const source = job.video || job.canvas;
    const sourceWidth = job.video ? job.video.videoWidth : job.canvas.width;
    const sourceHeight = job.video ? job.video.videoHeight : job.canvas.height;
    const sx = sourceWidth / job.bounds.width;
    const sy = sourceHeight / job.bounds.height;
    const image = document.createElement('canvas');
    image.width = Math.ceil(crop.width * scale);
    image.height = Math.ceil(crop.height * scale);
    image.getContext('2d', { willReadFrequently: true }).drawImage(source,
      (crop.left - job.bounds.left) * sx, (crop.top - job.bounds.top) * sy,
      crop.width * sx, crop.height * sy, 0, 0, image.width, image.height);
    return image;
  }

  function upperBrightness(image, region = { x0: 0, y0: 0, x1: image.width, y1: image.height }) {
    const pixels = image.getContext('2d').getImageData(
      region.x0, region.y0, region.x1 - region.x0, region.y1 - region.y0).data;
    const histogram = new Uint32Array(256);
    for (let i = 0; i < pixels.length; i += 4) {
      histogram[Math.round((pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3)]++;
    }
    let count = 0;
    for (let level = 255; level > 0; level--) {
      count += histogram[level];
      if (count >= pixels.length / 40) return level;
    }
    return 0;
  }

  function logoBrightness(job) {
    return upperBrightness(readCrop(job, { left: 16, top: 13, width: 90, height: 32 }));
  }

  function prepareOcrImage(image) {
    const context = image.getContext('2d');
    const pixels = context.getImageData(0, 0, image.width, image.height);
    const data = pixels.data;
    let total = 0;
    for (let i = 0; i < data.length; i += 4) total += data[i] + data[i + 1] + data[i + 2];
    if (total / (data.length * 0.75) < 120) {
      for (let i = 0; i < data.length; i += 4) {
        const luminance = (data[i] + data[i + 1] + data[i + 2]) / 3;
        const transformed = Math.min(255, Math.max(0, (215 - luminance) * 2));
        data[i] = data[i + 1] = data[i + 2] = transformed;
      }
      context.putImageData(pixels, 0, 0);
    }
    return image;
  }

  function channelNameFromText(text) {
    return text.normalize('NFKC').replace(/[\r\n]+/g, ' ')
      .replace(/\s*(?:[“‘"|]\s*)?\b\d{1,3}\s*\/\s*\d{1,3}\b.*$/, '')
      .replace(/(?<=\p{Script=Han})\s+(?=\p{Script=Han})/gu, '')
      .replace(/\s{2,}/g, ' ').trim();
  }

  function visualDismissCandidate(data) {
    const lines = (data.blocks || []).flatMap(block =>
      block.paragraphs.flatMap(paragraph => paragraph.lines));
    const matches = [];
    for (const line of lines) {
      const words = line.words;
      for (let start = 0; start < words.length; start++) {
        let label = '';
        for (const [index, word] of words.slice(start, start + 4).entries()) {
          if (word.confidence < 60) break;
          label += word.text.normalize('NFKC').replace(/\s/g, '');
          if (!'不感兴趣'.startsWith(label)) break;
          if (label !== '不感兴趣') continue;
          const pieces = words.slice(start, start + index + 1).map(piece => piece.bbox);
          const x0 = Math.min(...pieces.map(box => box.x0));
          const x1 = Math.max(...pieces.map(box => box.x1));
          const y0 = Math.max(line.bbox.y0, Math.min(...pieces.map(box => box.y0)));
          const y1 = Math.min(line.bbox.y1, Math.max(...pieces.map(box => box.y1)));
          if (x1 - x0 <= 180 && y1 - y0 <= 45 && x1 > x0 && y1 > y0) {
            matches.push({ x0, x1, y0, y1 });
          }
          break;
        }
      }
    }
    if (matches.length !== 1) return;
    const [button] = matches;
    if (lines.some(line => promotionLabel.test(line.text.replace(/\s/g, '')) && line.confidence > 50 &&
        line.bbox.y1 <= button.y0 && button.y0 - line.bbox.y1 < 380 &&
        line.bbox.x1 >= button.x0 - 260 && line.bbox.x0 <= button.x1 + 260)) return button;
  }

  function samePictureAt(before, after, box) {
    const region = [box.x0, box.y0, box.x1 - box.x0, box.y1 - box.y0];
    const first = before.getContext('2d').getImageData(...region).data;
    const second = after.getContext('2d').getImageData(...region).data;
    let difference = 0;
    for (let i = 0; i < first.length; i++) difference += Math.abs(first[i] - second[i]);
    return difference / first.length < 7;
  }

  async function scanVisualPopup(job, level) {
    if (popupAttempt?.dialog.isConnected && isVisible(popupAttempt.dialog)) return;
    if (job.clickedAt) {
      if (Date.now() - job.clickedAt > 4000) visualPopupMessage = '已点击，等待弹窗关闭';
      return;
    }
    const crop = { left: Math.round(innerWidth * 0.18), top: Math.round(innerHeight * 0.08),
      width: Math.round(innerWidth * 0.64), height: Math.round(innerHeight * 0.84) };
    const scale = 1.25;
    const image = readCrop(job, crop, scale);
    const input = document.createElement('canvas');
    input.width = image.width;
    input.height = image.height;
    input.getContext('2d', { willReadFrequently: true }).drawImage(image, 0, 0);
    await job.worker.setParameters({ tessedit_pageseg_mode: Tesseract.PSM.SPARSE_TEXT });
    const { data } = await job.worker.recognize(prepareOcrImage(input), {}, { blocks: true });
    if (visualJob !== job || document.hidden || visualLayout() !== job.layout) return;
    const button = visualDismissCandidate(data);
    if (!button || upperBrightness(image, button) < Math.max(150, level + 25)) {
      job.previousButton = undefined;
      visualPopupMessage = '看到前景变暗，等待明确的活动按钮';
      return;
    }
    const x = crop.left + (button.x0 + button.x1) / 2 * crop.width / image.width;
    const y = crop.top + (button.y0 + button.y1) / 2 * crop.height / image.height;
    const previous = job.previousButton;
    job.previousButton = { x, y };
    if (!previous || Math.hypot(x - previous.x, y - previous.y) > 5) {
      visualPopupMessage = '识别到「不感兴趣」，正在复核';
      return;
    }
    if (logoBrightness(job) >= job.baseline * 0.83 ||
        !samePictureAt(image, readCrop(job, crop, scale), button)) return;
    const hit = canvasTargetAt(x, y);
    if (!hit || hit.view !== job.view) return;
    job.clickedAt = Date.now();
    visualPopupMessage = '已点击「不感兴趣」，等待画面恢复';
    tapPoint(hit.target, x, y);
  }

  async function scanVisual(job) {
    if (visualJob !== job || job.busy || document.hidden) return;
    if (visualLayout() !== job.layout || !job.canvas.isConnected) {
      visualChannel = '';
      stopVisual('窗口布局已变化，请重新开始识别');
      return;
    }
    job.busy = true;
    try {
      const level = logoBrightness(job);
      if (level < 15) {
        if (++job.blankFrames >= 3) stopVisual('画面取帧失败', !job.tabCapture);
        return;
      }
      job.blankFrames = 0;
      if (level < job.baseline * 0.83 && job.baseline - level > 23) {
        await scanVisualPopup(job, level);
      } else {
        if (job.clickedAt) visualPopupMessage = '已点击「不感兴趣」，活动画面已关闭';
        else if (!visualPopupMessage.endsWith('已关闭')) visualPopupMessage = '';
        job.clickedAt = undefined;
        job.previousButton = undefined;
        job.baseline = Math.max(job.baseline, level);
        if (Date.now() < job.nextTitleAt) return;
        job.nextTitleAt = Date.now() + 4500;
        const crop = { left: 351, top: 64, width: Math.min(310, innerWidth - 351), height: 40 };
        const image = prepareOcrImage(readCrop(job, crop, 2.5));
        await job.worker.setParameters({ tessedit_pageseg_mode: Tesseract.PSM.SINGLE_LINE });
        const { data } = await job.worker.recognize(image);
        if (visualJob !== job || visualLayout() !== job.layout) return;
        job.titleChecked = true;
        const name = channelNameFromText(data.text);
        visualChannel = data.confidence >= 60 && name.length <= 80 && /[\p{Letter}\p{Number}]/u.test(name)
          ? name : '';
      }
    } catch {
      if (visualJob === job) stopVisual('当前画面无法完成识别', !job.tabCapture);
    } finally {
      job.busy = false;
      update();
    }
  }

  function stopVisual(message, useTab = false) {
    const job = visualJob;
    visualJob = undefined;
    if (job) {
      clearInterval(job.timer);
      clearTimeout(job.startTimer);
      job.stream?.getTracks().forEach(track => track.stop());
      if (job.video) job.video.srcObject = null;
      job.worker?.terminate().catch(() => {});
    }
    offerTabCapture = useTab;
    visualMessage = message;
    update();
  }

  async function useVideoFrames(job, stream) {
    job.stream = stream;
    for (const track of stream.getTracks()) {
      track.addEventListener('ended', () => {
        if (visualJob === job) stopVisual('取帧已停止', !job.tabCapture);
      }, { once: true });
    }
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    job.video = video;
    await video.play();
  }

  async function startVisual(tabCapture) {
    if (visualJob) return;
    const glass = document.querySelector('flt-glass-pane');
    const canvas = glass?.shadowRoot?.querySelector('canvas');
    const view = glass?.closest('flutter-view');
    const bounds = canvas?.getBoundingClientRect();
    if (!view || !bounds || Math.abs(bounds.width - innerWidth) > 3 ||
        Math.abs(bounds.height - innerHeight) > 3 || innerWidth < 900 || innerHeight < 450) {
      stopVisual('请在桌面布局下打开频道再开始识别', offerTabCapture);
      return;
    }
    const job = { canvas, view, bounds, tabCapture, layout: visualLayout(), blankFrames: 0, nextTitleAt: 0 };
    visualJob = job;
    visualChannel = '';
    visualPopupMessage = '';
    visualMessage = '正在取帧并准备本地 OCR';
    const startTimeout = () => setTimeout(() => {
      if (visualJob === job) stopVisual('取帧或加载 OCR 超时', !tabCapture);
    }, 26000);
    if (!tabCapture) job.startTimer = startTimeout();
    update();
    try {
      if (tabCapture) {
        if (!window.CropTarget?.fromElement) throw new Error('当前浏览器无法限定当前标签画面');
        const cropTarget = window.CropTarget.fromElement(canvas);
        cropTarget.catch(() => {});
        const stream = await navigator.mediaDevices.getDisplayMedia({
          video: { displaySurface: 'browser' }, audio: false, preferCurrentTab: true,
          surfaceSwitching: 'exclude', monitorTypeSurfaces: 'exclude'
        });
        job.stream = stream;
        const [track] = stream.getVideoTracks();
        if (visualJob !== job) {
          stream.getTracks().forEach(item => item.stop());
          return;
        }
        job.startTimer = startTimeout();
        if (!track || track.getSettings().displaySurface !== 'browser' || !track.cropTo) {
          throw new Error('请选择当前 Oopz 标签页');
        }
        await track.cropTo(await cropTarget);
        await useVideoFrames(job, stream);
      } else {
        let level = 0;
        try { level = logoBrightness(job); } catch { /* A GPU canvas can be unreadable between draws. */ }
        if (level < 70) {
          await useVideoFrames(job, canvas.captureStream(5));
        }
      }
      if (visualJob !== job) return;
      job.baseline = logoBrightness(job);
      if (job.baseline < 90) throw new Error('未取得频道画面，请回到频道后重试');
      if (typeof Tesseract === 'undefined') throw new Error('OCR 引擎未加载');
      const worker = await Tesseract.createWorker(['chi_sim', 'eng'], 1, {
        workerPath: 'https://cdn.jsdelivr.net/npm/tesseract.js@6.0.1/dist/worker.min.js',
        corePath: 'https://cdn.jsdelivr.net/npm/tesseract.js-core@6.1.2',
        errorHandler: () => {
          if (visualJob === job) stopVisual('OCR 模型加载或运行失败');
        }
      });
      if (visualJob !== job) {
        await worker.terminate();
        return;
      }
      job.worker = worker;
      clearTimeout(job.startTimer);
      visualMessage = tabCapture ? '本标签画面 · 本地 OCR' :
        (job.video ? '画布取帧 · 本地 OCR' : '画布直读 · 本地 OCR');
      job.timer = setInterval(() => { scanVisual(job); }, 1800);
      await scanVisual(job);
    } catch (error) {
      if (visualJob === job) {
        const message = tabCapture ? '请选择当前 Oopz 标签页后重试' :
          (error.message === 'OCR 引擎未加载' ? error.message : '画布取帧失败，可使用当前标签画面');
        stopVisual(message, tabCapture || error.message !== 'OCR 引擎未加载');
      }
    }
  }

  visualButton.addEventListener('click', event => {
    if (!event.isTrusted) return;
    if (visualJob) stopVisual('画面识别已停止');
    else startVisual(false);
  });
  tabCaptureButton.addEventListener('click', event => {
    if (event.isTrusted) startVisual(true);
  });
  window.addEventListener('pagehide', () => { if (visualJob) stopVisual('画面识别已停止'); });

  function updatePopup(nodes) {
    const match = findDismissButton(nodes);
    if (popupAttempt) {
      if (!popupAttempt.checked && !match.found &&
          (!popupAttempt.dialog.isConnected || !isVisible(popupAttempt.dialog))) {
        popupMessage = '已点「不感兴趣」，活动弹窗已关闭';
        popupAttempt.checked = true;
      } else if (!popupAttempt.checked && Date.now() >= popupAttempt.until) {
        popupMessage = '已点击，未确认弹窗关闭';
        popupAttempt.checked = true;
      }
      return;
    }
    if (!match.button) {
      popupMessage = match.found ? '看到不感兴趣，等待确认活动弹窗' : '等待活动弹窗';
      return;
    }
    popupAttempt = { dialog: match.dialog, until: Date.now() + 6000, checked: false };
    popupMessage = '已点击不感兴趣，等待网页确认';
    match.button.click();
  }

  function pageControls(roots) {
    return roots.flatMap(root =>
      [...root.querySelectorAll(`${buttonSelector}, flt-semantics[aria-label], [role="status"], [aria-current="true"]`)]
        .filter(element => !panel.contains(element)));
  }

  function update() {
    if (document.hidden) return;
    const roots = flutterRoots();
    for (const root of roots) {
      const placeholder = root.querySelector('flt-semantics-placeholder[aria-label="Enable accessibility"]');
      if (placeholder && !activatedPlaceholders.has(placeholder)) {
        activatedPlaceholders.add(placeholder);
        placeholder.click();
      }
    }

    const nodes = pageControls(roots);
    const hasSemanticsTree = roots.some(root => root.querySelector('flt-semantics'));
    const semanticsReady = nodes.some(element => element.matches('flt-semantics') &&
      (element.hasAttribute('flt-tappable') || readLabel(element)));
    updatePopup(nodes);
    const channel = readChannel(nodes);
    const microphone = readMicrophone(nodes);
    if (muteAttempt && microphone?.state === muteAttempt.expected) {
      muteMessage = '已确认网页状态改变';
      muteAttempt = undefined;
    } else if (muteAttempt && Date.now() >= muteAttempt.until) {
      muteMessage = '已发送操作，网页未确认';
      muteAttempt = undefined;
    }

    const useCanvas = !microphone && roots.some(root =>
      root.host?.matches('flt-glass-pane') && root.querySelector('canvas'));
    const canvasTarget = useCanvas && calibratedTarget();
    calibrateButton.hidden = !useCanvas;
    calibrateButton.disabled = !!calibrationLayer;
    muteButton.disabled = (!microphone && !canvasTarget) || !!muteAttempt || !!calibrationLayer;
    muteButton.style.opacity = muteButton.disabled ? '0.45' : '1';
    visualButton.textContent = visualJob ? '停止识别' : '识别频道和弹窗';
    tabCaptureButton.hidden = !offerTabCapture || !!visualJob;
    muteButton.textContent = useCanvas ? '测试切换麦克风' :
      (microphone?.state === 'muted' ? '测试解除静音' : '测试静音');
    const status = [
      semanticsReady ? '已读到网页无障碍控件' :
        (hasSemanticsTree ? '网页只提供空的无障碍节点' : '正在等待网页无障碍控件'),
      `弹窗 · ${visualPopupMessage || popupMessage}`,
      `频道 · ${channel || (visualChannel ? `${visualChannel}（画面）` :
        (visualJob ? (visualJob.titleChecked ? '标题未读清' : '正在识别标题') :
          (useCanvas && !semanticsReady ? '可启动画面识别' : '未识别当前语音频道')))}`,
      `麦克风 · ${microphone ? (microphone.state === 'muted' ? '已静音' : '开启') :
        (canvasTarget ? '已标定，状态看原网页' :
          (microphonePoint ? '位置已保存，暂不可点击' : '未识别'))}`,
      muteMessage,
      visualMessage
    ].filter(Boolean).join('\n');
    if (output.textContent !== status) output.textContent = status;
  }

  muteButton.addEventListener('click', event => {
    if (muteAttempt || calibrationLayer || document.hidden || !event.isTrusted) return;
    const nodes = pageControls(flutterRoots());
    const microphone = readMicrophone(nodes);
    if (!microphone) {
      const target = calibratedTarget();
      if (target) {
        tapPoint(target, microphonePoint.x, microphonePoint.y);
        muteMessage = '已发送点击，请看左上角原图标确认';
      }
      update();
      return;
    }
    muteAttempt = { expected: microphone.state === 'on' ? 'muted' : 'on', until: Date.now() + 4000 };
    muteButton.disabled = true;
    muteMessage = '等待网页更新麦克风状态';
    microphone.element.click();
    update();
  });

  update();
  window.setInterval(update, 500);
})();

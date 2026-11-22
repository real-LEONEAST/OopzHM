import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { isCallUsage, VoiceRouteStatus } from './VoiceAudioRoute';

const LOG_TAG = 'OopzVoiceTest';

export enum VoiceTaskState {
  RUNNING,
  SUSPENDED,
  ABSENT
}

export class VoiceBackgroundTest {
  private readonly source: 'native' | 'web';
  private session?: avSession.AVSession;
  private audioFocus?: audio.AudioSessionManager;
  private running: boolean = false;
  private taskId?: number;

  constructor(source: 'native' | 'web' = 'native') {
    this.source = source;
  }

  isRunning(): boolean {
    return this.running;
  }

  matchesTask(id: number): boolean {
    return this.running && this.taskId === id;
  }

  async startCall(context: common.UIAbilityContext, route: VoiceRouteStatus, capturing: boolean,
    canRetry: () => boolean): Promise<void> {
    const modes: string[] = [];
    const voiceCall = isCallUsage(route.usage) ||
      (route.usage === undefined && route.source === audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
    if (voiceCall) {
      modes.push('voip');
    } else {
      if (capturing) modes.push('audioRecording');
      if (route.usage !== undefined) modes.push('audioPlayback');
    }
    if (voiceCall && deviceInfo.apiAvailable(22)) {
      try {
        await this.start(context, false, ['voip'], true);
        return;
      } catch (error) {
        hilog.info(0x0, LOG_TAG, 'Multimedia task unavailable, code=%{public}d', (error as BusinessError).code);
        if (!canRetry()) throw error as Error;
      }
    }
    if (modes.length > 0) await this.start(context, false, modes);
  }

  async start(context: common.UIAbilityContext, webPlaying: boolean = false, activeCallModes?: string[],
    voiceChatRequest: boolean = false): Promise<void> {
    try {
      const notificationTarget = await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });

      // Live calls own their AVSession independently of background task approval or cancellation.
      if (activeCallModes === undefined) {
        const session = await avSession.createAVSession(context, 'OopzVoiceTest',
          this.source === 'web' ? 'audio' : 'voice_call');
        this.session = session;
        if (this.source === 'web') {
          await session.setAVMetadata({ assetId: 'oopz-web-voice', title: 'Oopz 网页语音' });
          await this.updateWebPlayback(webPlaying);
        }
        await session.activate();
      }
      if (this.source === 'web') {
        try {
          const manager = audio.getAudioManager().getSessionManager();
          await manager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS });
          this.audioFocus = manager;
        } catch (error) {
          hilog.warn(0x0, LOG_TAG, 'Unable to request mixed audio focus, code=%{public}d', (error as BusinessError).code);
        }
      }
      const modes = activeCallModes ?? ['audioPlayback', 'audioRecording'];
      let task: backgroundTaskManager.ContinuousTaskNotification;
      if (voiceChatRequest && deviceInfo.apiAvailable(22)) {
        const request = new backgroundTaskManager.ContinuousTaskRequest();
        request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD];
        request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_VOICE_CHAT_NORMAL_NOTIFICATION];
        request.wantAgent = notificationTarget;
        task = await backgroundTaskManager.startBackgroundRunning(context, request);
      } else {
        task = await backgroundTaskManager.startBackgroundRunning(context, modes, notificationTarget);
      }
      this.taskId = task.continuousTaskId;
      this.running = true;
      hilog.info(0x0, LOG_TAG, 'Continuous task accepted, modes=%{public}s',
        voiceChatRequest ? 'avPlaybackAndRecord/voiceChat' : modes.join(','));
    } catch (error) {
      await this.releaseSession();
      throw error as Error;
    }
  }

  async updateWebPlayback(playing: boolean): Promise<void> {
    const session = this.session;
    if (this.source !== 'web' || session === undefined) {
      return;
    }
    try {
      await session.setAVPlaybackState({
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
      });
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Unable to sync web session playback, code=%{public}d', (error as BusinessError).code);
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      try {
        if (deviceInfo.apiAvailable(21)) {
          if (this.taskId !== undefined && this.taskId >= 0) {
            await backgroundTaskManager.stopBackgroundRunning(context, this.taskId);
            await this.taskEnded();
            return;
          }
        }
        await backgroundTaskManager.stopBackgroundRunning(context);
      } catch (error) {
        if (this.running) {
          throw error as Error;
        }
      }
    }
    await this.taskEnded();
  }

  async inspect(context: common.UIAbilityContext): Promise<VoiceTaskState | undefined> {
    if (deviceInfo.apiAvailable(20)) {
      const tasks = await backgroundTaskManager.getAllContinuousTasks(context, true);
      const task = tasks.find((candidate: backgroundTaskManager.ContinuousTaskInfo) => {
        if (candidate.isFromWebView || candidate.abilityName !== context.abilityInfo.name) {
          return false;
        }
        return this.taskId === undefined || this.taskId < 0 || candidate.continuousTaskId === this.taskId;
      });
      if (task === undefined) {
        return VoiceTaskState.ABSENT;
      }
      return task.suspendState ? VoiceTaskState.SUSPENDED : VoiceTaskState.RUNNING;
    }
    return undefined;
  }

  async taskEnded(): Promise<void> {
    this.running = false;
    this.taskId = undefined;
    await this.releaseSession();
  }

  private async releaseSession(): Promise<void> {
    const session = this.session;
    this.session = undefined;
    const audioFocus = this.audioFocus;
    this.audioFocus = undefined;
    if (session !== undefined) {
      try {
        await session.destroy();
      } catch (error) {
        hilog.warn(0x0, LOG_TAG, 'Unable to destroy AVSession, code=%{public}d', (error as BusinessError).code);
      }
    }
    if (audioFocus !== undefined) {
      try {
        await audioFocus.deactivateAudioSession();
      } catch (error) {
        hilog.warn(0x0, LOG_TAG, 'Unable to release audio focus, code=%{public}d', (error as BusinessError).code);
      }
    }
  }
}

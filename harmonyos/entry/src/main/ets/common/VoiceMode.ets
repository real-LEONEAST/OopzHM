export type VoiceMode = 'standard' | 'native-voip';

export function voiceModeLabel(mode: VoiceMode): string {
  return mode === 'native-voip' ? '鸿蒙原生 VoIP' : '标准语音';
}

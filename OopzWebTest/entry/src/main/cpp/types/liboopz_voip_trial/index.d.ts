export const join: (appId: string, channel: string, uid: number, token: string, liveRoom: boolean,
  onSignal: (signal: number[]) => void) => number[];
export const close: () => void;
export const push: (buffer: ArrayBuffer) => number;
export const pull: (buffer: ArrayBuffer) => number;
export const stats: () => number[];
export const renewToken: (token: string) => number;
export const muteRemote: (uid: number, muted: boolean) => number;
export const setRemoteVolume: (uid: number, volume: number) => number;

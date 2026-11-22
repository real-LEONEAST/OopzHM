import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';

// HarmonyOS immersive glass theme tokens supporting adaptive Light & Dark modes.
export interface ThemePalette {
  bg: string;
  rail: string;
  canvasTint: string;
  surface: string;
  surfaceSolid: string;
  surfaceAlt: string;
  tint: string;
  border: string;
  borderSubtle: string;
  specularBorder: string;
  accent: string;
  accentSoft: string;
  accentText: string;
  speaking: string;
  speakingSoft: string;
  text: string;
  textSecondary: string;
  textMuted: string;
  dangerFill: string;
  dangerText: string;
  warn: string;
  warnSoft: string;
  glass: string;
  glassStrong: string;
  chromeTint: string;
  chromeHighlight: string;
  glowTop: string;
  glowBottom: string;
  scrimStart: string;
  scrimMid: string;
  scrimEnd: string;
  shadowColor: string;
  blurColorMode: ThemeColorMode;
  isDark: boolean;
}

export const DARK_THEME: ThemePalette = {
  bg: '#181B1E',
  rail: '#14171A',
  canvasTint: '#1B1E21',
  surface: '#222629',
  surfaceSolid: '#212528',
  surfaceAlt: '#2C3134',
  tint: '#293A37',
  border: '#41474B',
  borderSubtle: '#33383B',
  specularBorder: '#47CBEEE3',
  accent: '#A5E4D0',
  accentSoft: '#2B403C',
  accentText: '#142B25',
  speaking: '#81DDA8',
  speakingSoft: '#274033',
  text: '#F2F4F2',
  textSecondary: '#C4CAC7',
  textMuted: '#A5AEAA',
  dangerFill: '#AA3547',
  dangerText: '#FFF6F6',
  warn: '#F0C17C',
  warnSoft: '#3F3428',
  glass: '#D0222629',
  glassStrong: '#EB222629',
  chromeTint: '#D82B3B36',
  chromeHighlight: '#38BFEEE0',
  glowTop: '#22A5E4D0',
  glowBottom: '#12D8BBA0',
  scrimStart: '#EB181B1E',
  scrimMid: '#85181B1E',
  scrimEnd: '#1A181B1E',
  shadowColor: '#42000000',
  blurColorMode: ThemeColorMode.DARK,
  isDark: true
};

export const LIGHT_THEME: ThemePalette = {
  bg: '#FAF9F6',
  rail: '#E8EAEB',
  canvasTint: '#F0F1F1',
  surface: '#F3F2EF',
  surfaceSolid: '#FCFBF8',
  surfaceAlt: '#E9E9E6',
  tint: '#E4EEE9',
  border: '#D5D8D5',
  borderSubtle: '#E0E1DE',
  specularBorder: '#F0FFFFFF',
  accent: '#136451',
  accentSoft: '#D8EAE4',
  accentText: '#FFFFFF',
  speaking: '#23794B',
  speakingSoft: '#E0EEE3',
  text: '#202628',
  textSecondary: '#4A5553',
  textMuted: '#596360',
  dangerFill: '#AC3748',
  dangerText: '#FFFFFF',
  warn: '#8A591F',
  warnSoft: '#F5EADB',
  glass: '#DEF9F8F4',
  glassStrong: '#F0FCFBF8',
  chromeTint: '#EAF1FAF7',
  chromeHighlight: '#DEFFFFFF',
  glowTop: '#188AC8B5',
  glowBottom: '#18DFC1A5',
  scrimStart: '#CC0F172A',
  scrimMid: '#660F172A',
  scrimEnd: '#140F172A',
  shadowColor: '#1A0F172A',
  blurColorMode: ThemeColorMode.LIGHT,
  isDark: false
};

export function getTheme(isDark: boolean): ThemePalette {
  return isDark ? DARK_THEME : LIGHT_THEME;
}

export function resolveIsDark(mode: string, systemIsDark: boolean): boolean {
  if (mode === 'dark') {
    return true;
  }
  if (mode === 'light') {
    return false;
  }
  return systemIsDark;
}

const MATERIAL_CACHE: Map<string, uiMaterial.Material> = new Map<string, uiMaterial.Material>();

export function supportsImmersiveLight(): boolean {
  if (!deviceInfo.apiAvailable('26.0.0')) {
    return false;
  }
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch {
    return false;
  }
}

// Thickness levels: 0=ULTRA_THIN, 1=THIN, 2=REGULAR, 3=THICK, 4=ULTRA_THICK.
export function createImmersiveMaterial(thickness: number, isDark: boolean, interactive: boolean = false,
  materialColor?: ResourceColor): uiMaterial.Material | undefined {
  if (!supportsImmersiveLight()) {
    return undefined;
  }
  const cacheKey = materialColor === undefined
    ? `${thickness}_${isDark ? 1 : 0}_${interactive ? 1 : 0}`
    : '';
  if (cacheKey.length > 0) {
    const cached = MATERIAL_CACHE.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }
  }
  try {
    let style = uiMaterial.ImmersiveStyle.REGULAR;
    if (thickness === 0) {
      style = uiMaterial.ImmersiveStyle.ULTRA_THIN;
    } else if (thickness === 1) {
      style = uiMaterial.ImmersiveStyle.THIN;
    } else if (thickness === 3) {
      style = uiMaterial.ImmersiveStyle.THICK;
    } else if (thickness === 4) {
      style = uiMaterial.ImmersiveStyle.ULTRA_THICK;
    }
    const mat = new uiMaterial.ImmersiveMaterial({
      style: style,
      materialColor: materialColor ?? (isDark ? '#80233432' : '#88EBF7F3'),
      applyShadow: interactive,
      interactive: interactive,
      lightEffect: {
        color: isDark ? '#42A5E4D0' : '#62FFFFFF'
      }
    });
    if (cacheKey.length > 0) {
      MATERIAL_CACHE.set(cacheKey, mat);
    }
    return mat;
  } catch {
    return undefined;
  }
}

export class ImmersiveChrome implements AttributeModifier<CommonAttribute> {
  private readonly enabled: boolean;
  private readonly isDark: boolean;
  private readonly thickness: number;
  private readonly interactive: boolean;

  constructor(enabled: boolean, isDark: boolean, thickness: number, interactive: boolean = false) {
    this.enabled = enabled;
    this.isDark = isDark;
    this.thickness = thickness;
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const theme = getTheme(this.isDark);
    const material = this.enabled ? createImmersiveMaterial(this.thickness, this.isDark, this.interactive) : undefined;
    if (material === undefined && deviceInfo.apiAvailable('26.0.0')) {
      instance.systemMaterial(uiMaterial.Material.empty);
    }

    // Custom bars also need a visible treatment on surfaces where ArkUI cannot render a system material.
    instance.backgroundColor(this.enabled ? theme.chromeTint : theme.surfaceSolid);
    instance.borderColor(this.enabled ? theme.specularBorder : theme.borderSubtle);
    instance.backgroundEffect({ radius: this.enabled ? 12 : 0, color: Color.Transparent });
    instance.linearGradient({
      direction: GradientDirection.Bottom,
      colors: [[this.enabled ? theme.chromeHighlight : Color.Transparent, 0],
        [Color.Transparent, 0.56], [Color.Transparent, 1]]
    });
    if (material !== undefined) {
      instance.systemMaterial(material);
    }
  }
}

export class AppSpacing {
  static readonly page: number = 20;
  static readonly card: number = 16;
  static readonly gap: number = 14;
  static readonly radiusLg: number = 24;
  static readonly radius: number = 16;
  static readonly radiusSm: number = 12;
  static readonly navHeight: number = 56;
}

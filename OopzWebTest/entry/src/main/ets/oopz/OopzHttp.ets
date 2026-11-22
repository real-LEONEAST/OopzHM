// Thin native HTTP wrapper around @ohos.net.http and @kit.RemoteCommunicationKit (for PATCH on API 13+).

import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';

export interface HttpResult {
  status: number;
  text: string;
}

function methodOf(method: string): http.RequestMethod {
  if (method === 'POST') {
    return http.RequestMethod.POST;
  }
  if (method === 'DELETE') {
    return http.RequestMethod.DELETE;
  }
  if (method === 'PUT') {
    return http.RequestMethod.PUT;
  }
  return http.RequestMethod.GET;
}

async function sendPatchWithRcp(url: string, header: Record<string, string>, body?: string): Promise<HttpResult> {
  const rcpHeaders: rcp.RequestHeaders = {};
  const keys = Object.keys(header);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    rcpHeaders[key] = header[key];
  }
  const payload: string | undefined = (body !== undefined && body.length > 0) ? body : undefined;
  const req = new rcp.Request(url, 'PATCH', rcpHeaders, payload);
  const session = rcp.createSession({
    requestConfiguration: {
      transfer: {
        timeout: {
          connectMs: 8000,
          transferMs: 25000
        }
      }
    }
  });
  try {
    const resp = await session.fetch(req);
    const text = resp.toString();
    return { status: resp.statusCode, text: text !== null ? text : '' };
  } finally {
    session.close();
  }
}

export async function httpSend(method: string, url: string, header: Record<string, string>,
  body?: string): Promise<HttpResult> {
  if (method === 'PATCH') {
    return await sendPatchWithRcp(url, header, body);
  }
  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: methodOf(method),
      header: header,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false,
      usingProxy: false,
      connectTimeout: 8000,
      readTimeout: 25000
    };
    const response = await request.request(url, options);
    const text: string = typeof response.result === 'string' ? response.result as string : '';
    return { status: response.responseCode, text: text };
  } finally {
    request.destroy();
  }
}

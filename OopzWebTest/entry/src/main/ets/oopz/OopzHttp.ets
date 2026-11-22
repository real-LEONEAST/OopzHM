// Thin native HTTP wrapper around @ohos.net.http.

import { http } from '@kit.NetworkKit';

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

export async function httpSend(method: string, url: string, header: Object, body?: string): Promise<HttpResult> {
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

import type { Route, Services, Context, Request, Response } from '../types.ts';
import { ApiError } from '../errors.ts';
import { errorResponse } from './response.ts';
export function routeRequest(routes: readonly Route[], services: Services, request: Request, context: Context): Response {
  try {
    for (const route of routes) {
      if (route.method !== request.method) continue;
      const template = route.path.split('/'); const actual = request.path.split('/');
      if (template.length !== actual.length) continue;
      const params: Record<string, string> = {}; let match = true;
      for (let i = 0; i < template.length; i++) {
        if (template[i].startsWith(':')) params[template[i].slice(1)] = actual[i];
        else if (template[i] !== actual[i]) { match = false; break; }
      }
      if (!match) continue;
      if (route.requiresActor && !context.actorId?.trim()) throw new ApiError('unauthorized', 'actor required');
      return route.handle(request, context, services, params);
    }
    throw new ApiError('missing', 'route not found');
  } catch (error) { return errorResponse(error); }
}

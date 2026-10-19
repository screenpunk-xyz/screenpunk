// Pinned validation projection of schemas/dashboard-manifest.schema.json.
// Schema SHA256: 5412a16a3f5d034f5e4735b0e5c132a2886359a46f0807b27becdb82fd5d8d87
// Only annotation keywords are removed. Keep synchronized through the schema parity test.
export const nativeManifestSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "schemaVersion",
    "dashboardId",
    "name",
    "revision",
    "entrypoint",
    "sdkVersion",
    "target",
    "connections",
    "files",
  ],
  properties: {
    schemaVersion: { type: "integer", const: 1 },
    dashboardId: { type: "string", format: "uuid" },
    name: { type: "string", minLength: 1, maxLength: 128 },
    revision: { type: "string", format: "uuid" },
    entrypoint: {
      type: "string",
      pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+\\.html$",
    },
    sdkVersion: { type: "string", const: "1" },
    digest: { type: "string", pattern: "^[a-f0-9]{64}$" },
    target: {
      type: "object",
      additionalProperties: false,
      required: ["profileId", "width", "height", "scale", "orientation"],
      properties: {
        profileId: { type: "string", minLength: 1, maxLength: 128 },
        width: { type: "integer", minimum: 1, maximum: 10000 },
        height: { type: "integer", minimum: 1, maximum: 10000 },
        scale: { type: "number", exclusiveMinimum: 0, maximum: 8 },
        orientation: { enum: ["portrait", "landscape"] },
        safeArea: {
          type: "object",
          additionalProperties: false,
          required: ["top", "right", "bottom", "left"],
          properties: {
            top: { type: "number", minimum: 0 },
            right: { type: "number", minimum: 0 },
            bottom: { type: "number", minimum: 0 },
            left: { type: "number", minimum: 0 },
          },
        },
      },
    },
    connections: {
      type: "array",
      maxItems: 64,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["alias", "required"],
        properties: {
          alias: {
            type: "string",
            minLength: 1,
            maxLength: 64,
            pattern: "^[A-Za-z][A-Za-z0-9_-]*$",
          },
          required: { type: "boolean" },
          cameraEntities: {
            type: "array",
            maxItems: 16,
            uniqueItems: true,
            items: {
              type: "string",
              maxLength: 255,
              pattern: "^camera\\.[a-z0-9_]+$",
            },
          },
          serviceCalls: {
            type: "array",
            maxItems: 128,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["domain", "service", "entityIds"],
              properties: {
                domain: {
                  type: "string",
                  pattern: "^[a-z0-9_]+$",
                  maxLength: 128,
                  minLength: 1,
                },
                service: {
                  type: "string",
                  pattern: "^[a-z0-9_]+$",
                  maxLength: 128,
                  minLength: 1,
                },
                entityIds: {
                  type: "array",
                  maxItems: 128,
                  uniqueItems: true,
                  items: {
                    type: "string",
                    maxLength: 255,
                    pattern: "^[a-z0-9_]+\\.[a-z0-9_]+$",
                  },
                },
                allowUntargeted: { type: "boolean" },
              },
            },
          },
          operations: {
            type: "array",
            maxItems: 32,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["name", "kind"],
              properties: {
                name: {
                  type: "string",
                  minLength: 1,
                  maxLength: 64,
                  pattern: "^[A-Za-z][A-Za-z0-9_-]*$",
                },
                kind: { enum: ["http", "ws"] },
                maxAgeSeconds: { type: "integer", minimum: 1 },
              },
            },
          },
          publicHTTP: {
            type: "object",
            additionalProperties: false,
            required: ["origin", "userAgent", "operations"],
            properties: {
              origin: {
                type: "string",
                pattern: "^https://[a-z0-9]+(?:[.-][a-z0-9]+)*(?::443)?$",
              },
              userAgent: {
                type: "string",
                minLength: 1,
                maxLength: 256,
                pattern: "^[\\x20-\\x7e]+$",
              },
              operations: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "object",
                  additionalProperties: false,
                  required: [
                    "name",
                    "path",
                    "response",
                    "parameters",
                    "maxAgeSeconds",
                    "staleSeconds",
                  ],
                  properties: {
                    name: {
                      type: "string",
                      minLength: 1,
                      maxLength: 128,
                      pattern: "^[a-zA-Z0-9_.-]+$",
                    },
                    path: { type: "string", minLength: 1, maxLength: 512 },
                    response: { enum: ["json", "raster"] },
                    parameters: {
                      type: "object",
                      maxProperties: 12,
                      additionalProperties: {
                        type: "object",
                        additionalProperties: false,
                        required: ["location"],
                        properties: {
                          location: { enum: ["path", "query"] },
                          minimum: {
                            type: "integer",
                            minimum: -9007199254740991,
                            maximum: 9007199254740991,
                          },
                          maximum: {
                            type: "integer",
                            minimum: -9007199254740991,
                            maximum: 9007199254740991,
                          },
                          values: {
                            type: "array",
                            minItems: 1,
                            maxItems: 64,
                            uniqueItems: true,
                            items: {
                              type: "string",
                              minLength: 1,
                              maxLength: 256,
                              pattern: "^[\\x20-\\x7e]+$",
                            },
                          },
                          pathSegment: {
                            type: "object",
                            additionalProperties: false,
                            required: ["maxLength"],
                            properties: {
                              maxLength: {
                                type: "integer",
                                minimum: 1,
                                maximum: 256,
                              },
                            },
                          },
                        },
                        oneOf: [
                          {
                            required: ["minimum", "maximum"],
                            properties: {
                              minimum: {},
                              maximum: {},
                              values: false,
                              pathSegment: false,
                            },
                          },
                          {
                            required: ["values"],
                            properties: {
                              values: {},
                              minimum: false,
                              maximum: false,
                              pathSegment: false,
                            },
                          },
                          {
                            required: ["pathSegment"],
                            properties: {
                              location: { const: "path" },
                              minimum: false,
                              maximum: false,
                              values: false,
                            },
                          },
                        ],
                      },
                    },
                    maxAgeSeconds: {
                      type: "integer",
                      minimum: 1,
                      maximum: 86400,
                    },
                    staleSeconds: {
                      type: "integer",
                      minimum: 0,
                      maximum: 604800,
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    files: {
      type: "array",
      minItems: 1,
      maxItems: 2000,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["path", "bytes", "sha256"],
        properties: {
          path: {
            type: "string",
            pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+$",
          },
          bytes: { type: "integer", minimum: 1, maximum: 52428800 },
          sha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
        },
      },
    },
    pages: {
      type: "array",
      minItems: 1,
      maxItems: 64,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "name", "path"],
        properties: {
          id: { type: "string", pattern: "^[A-Za-z0-9_-]{1,128}$" },
          name: { type: "string", minLength: 1, maxLength: 128 },
          path: {
            type: "string",
            pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+\\.html$",
          },
        },
      },
    },
    defaultPageId: { type: "string", pattern: "^[A-Za-z0-9_-]{1,128}$" },
    eventRules: {
      type: "array",
      maxItems: 64,
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "id",
          "name",
          "source",
          "defaults",
          "priority",
          "userConfigurable",
          "allowedPageIds",
          "allowedReturnBehaviors",
          "allowTimeoutOverride",
        ],
        properties: {
          id: { type: "string", pattern: "^[A-Za-z0-9_-]{1,128}$" },
          name: { type: "string", minLength: 1, maxLength: 128 },
          source: {
            type: "object",
            additionalProperties: false,
            required: ["mode", "alias", "operation", "parameters"],
            properties: {
              mode: { enum: ["live", "poll"] },
              alias: { type: "string", minLength: 1, maxLength: 128 },
              operation: { type: "string", minLength: 1, maxLength: 128 },
              parameters: {
                type: "object",
                maxProperties: 32,
                additionalProperties: {
                  anyOf: [
                    { type: "string" },
                    { type: "number" },
                    { type: "boolean" },
                    { type: "null" },
                  ],
                },
              },
              pollIntervalSeconds: {
                type: "integer",
                minimum: 15,
                maximum: 86400,
              },
              refreshOperation: {
                type: "string",
                minLength: 1,
                maxLength: 128,
              },
              refreshAlias: { type: "string", minLength: 1, maxLength: 64 },
            },
          },
          filter: {
            type: "object",
            additionalProperties: false,
            required: ["field", "equals"],
            properties: {
              field: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              equals: {
                anyOf: [
                  { type: "string" },
                  { type: "number" },
                  { type: "boolean" },
                  { type: "null" },
                ],
              },
            },
          },
          condition: {
            type: "object",
            additionalProperties: false,
            required: ["field", "equals"],
            properties: {
              field: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              equals: {
                anyOf: [
                  { type: "string" },
                  { type: "number" },
                  { type: "boolean" },
                  { type: "null" },
                ],
              },
            },
          },
          defaults: {
            type: "object",
            additionalProperties: false,
            required: [
              "enabled",
              "pageId",
              "returnBehavior",
              "timeoutSeconds",
              "allowPayloadOverrides",
            ],
            properties: {
              enabled: { type: "boolean" },
              pageId: { type: "string", pattern: "^[A-Za-z0-9_-]{1,128}$" },
              returnBehavior: { enum: ["stay", "timeout", "conditionClear"] },
              timeoutSeconds: { type: "integer", minimum: 1, maximum: 3600 },
              allowPayloadOverrides: { type: "boolean" },
            },
          },
          priority: { type: "integer", minimum: -100, maximum: 100 },
          userConfigurable: { type: "boolean" },
          allowedPageIds: {
            type: "array",
            maxItems: 64,
            uniqueItems: true,
            items: { type: "string", pattern: "^[A-Za-z0-9_-]{1,128}$" },
          },
          allowedReturnBehaviors: {
            type: "array",
            maxItems: 3,
            uniqueItems: true,
            items: { enum: ["stay", "timeout", "conditionClear"] },
          },
          allowTimeoutOverride: { type: "boolean" },
          payload: {
            type: "object",
            additionalProperties: false,
            required: [],
            properties: {
              pageId: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              returnBehavior: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              timeoutSeconds: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              eventId: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              correlationId: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
              occurredAt: {
                type: "array",
                minItems: 1,
                maxItems: 16,
                items: {
                  type: "string",
                  minLength: 1,
                  maxLength: 128,
                  not: { enum: ["__proto__", "constructor", "prototype"] },
                },
              },
            },
          },
        },
      },
    },
    deviceBehavior: {
      type: "object",
      additionalProperties: false,
      properties: {
        temporaryActivation: {
          type: "object",
          additionalProperties: false,
          required: [
            "source",
            "entityId",
            "activeState",
            "inactiveState",
            "idAttribute",
            "startedAtAttribute",
            "expiresAtAttribute",
            "maxDurationSeconds",
          ],
          properties: {
            source: { const: "homeAssistant" },
            entityId: {
              type: "string",
              maxLength: 255,
              pattern: "^[a-z0-9_]+\\.[a-z0-9_]+$(?![\\s\\S])",
            },
            activeState: {
              type: "string",
              minLength: 1,
              maxLength: 128,
              pattern: "^[^\\u0000-\\u001f\\u007f-\\u009f]+$(?![\\s\\S])",
            },
            inactiveState: {
              type: "string",
              minLength: 1,
              maxLength: 128,
              pattern: "^[^\\u0000-\\u001f\\u007f-\\u009f]+$(?![\\s\\S])",
            },
            idAttribute: {
              type: "string",
              minLength: 1,
              maxLength: 128,
              pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])",
            },
            startedAtAttribute: {
              type: "string",
              minLength: 1,
              maxLength: 128,
              pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])",
            },
            expiresAtAttribute: {
              type: "string",
              minLength: 1,
              maxLength: 128,
              pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])",
            },
            maxDurationSeconds: { type: "integer", minimum: 1, maximum: 3600 },
          },
        },
        audio: {
          type: "object",
          additionalProperties: false,
          required: ["autoplay"],
          properties: { autoplay: { type: "boolean" } },
        },
      },
    },
  },
} as const;

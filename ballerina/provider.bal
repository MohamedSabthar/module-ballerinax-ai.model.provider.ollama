// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/data.jsondata;
import ballerina/http;

const DEFAULT_OLLAMA_SERVICE_URL = "http://localhost:11434";
const TOOL_ROLE = "tool";

# Provider represents a client for interacting with an Ollama language models.
public isolated client class ModelProvider {
    *ai:ModelProvider;
    private final http:Client ollamaClient;
    private final string modelType;
    private final readonly & map<json> modleParameters;

    # Initializes the client with the given connection configuration and model configuration.
    #
    # + modelType - The Ollama model name
    # + serviceUrl - The base URL for the Ollama API endpoint
    # + modleParameters - Additional model parameters
    # + connectionConfig - Additional connection configuration
    # + return - `nil` on success, otherwise an `ai:Error`. 
    public isolated function init(@display {label: "Model Type"} string modelType,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_OLLAMA_SERVICE_URL,
            @display {label: "Ollama Model Parameters"} *OllamaModelParameters modleParameters,
            @display {label: "Connection Configuration"} *ConnectionConfig connectionConfig) returns ai:Error? {
        http:ClientConfiguration clientConfig = {...connectionConfig};
        http:Client|error ollamaClient = new (serviceUrl, clientConfig);
        if ollamaClient is error {
            return error ai:Error("Error while connecting to the model", ollamaClient);
        }
        self.modleParameters = check getModelParameterMap(modleParameters);
        self.ollamaClient = ollamaClient;
        self.modelType = modelType;
    }

    # Sends a chat request to the Ollama model with the given messages and tools.
    #
    # + messages - List of chat messages 
    # + tools - Tool definitions to be used for the tool call
    # + stop - Stop sequence to stop the completion
    # + return - Function to be called, chat response or an error in-case of failures
    isolated remote function chat(ai:ChatMessage[] messages, ai:ChatCompletionFunctions[] tools = [], string? stop = ())
        returns ai:ChatAssistantMessage|ai:LlmError {
        // Ollama chat completion API reference: https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion
        json requestPayload = self.prepareRequestPayload(messages, tools, stop);
        OllamaResponse|error response = self.ollamaClient->/api/chat.post(requestPayload);
        if response is error {
            return error ai:LlmConnectionError("Error while connecting to ollama", response);
        }
        return self.mapOllamaResponseToAssistantMessage(response);
    }

    private isolated function prepareRequestPayload(ai:ChatMessage[] messages, ai:ChatCompletionFunctions[] tools,
            string? stop) returns json {
        json[] transformedMessages = messages.'map(isolated function(ai:ChatMessage message) returns json {
            if message is ai:ChatFunctionMessage {
                return {role: TOOL_ROLE, content: message?.content};
            }
            return message;
        });

        map<json> options = {...self.modleParameters};
        if stop is string {
            options["stop"] = [stop];
        }

        map<json> payload = {
            model: self.modelType,
            messages: transformedMessages,
            'stream: false,
            options
        };
        if tools.length() > 0 {
            payload["tools"] = tools.'map(tool => {'type: ai:FUNCTION, 'function: tool});
        }
        return payload;
    }

    private isolated function mapOllamaResponseToAssistantMessage(OllamaResponse response)
        returns ai:ChatAssistantMessage {
        OllamaToolCall[]? toolCalls = response.message?.tool_calls;
        if toolCalls is OllamaToolCall[] {
            return self.mapToolCallsToAssistantMessage(toolCalls);
        }
        return {role: ai:ASSISTANT, content: response.message.content};
    }

    private isolated function mapToolCallsToAssistantMessage(OllamaToolCall[] ollamaToolCalls)
        returns ai:ChatAssistantMessage {
        ai:FunctionCall[] toolCalls = from OllamaToolCall toolCall in ollamaToolCalls
            select {
                name: toolCall.'function.name,
                arguments: toolCall.'function.arguments
            };
        return {role: ai:ASSISTANT, toolCalls};
    }
}

isolated function getModelParameterMap(OllamaModelParameters modleParameters) returns readonly & map<json>|ai:Error {
    do {
        json options = jsondata:toJson(modleParameters);
        map<json> & readonly readonlyOptions = check options.cloneWithType();
        return readonlyOptions;
    } on fail error e {
        return error ai:Error("Error while processing model parameters", e);
    }
}

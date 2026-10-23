import Foundation

struct SolutionGatewayExample: Identifiable {
    var id: String
    var title: String
    var script: String
}

@MainActor enum SolutionGatewayExamples {
    static func all(_ deployment: SolutionDeployment, endpoint: String) -> [SolutionGatewayExample] {
        let header = """
        #!/bin/sh
        set -eu
        MODELDOCK_BASE_URL=\(ConnectionFiles.quote(endpoint))
        # Export your unified gateway API key before running this example.
        : "${MODELDOCK_API_KEY:?Set MODELDOCK_API_KEY to your gateway API key}"

        """
        let curl = "curl --fail-with-body --silent --show-error --header \"Authorization: Bearer $MODELDOCK_API_KEY\""
        func get(_ path: String) -> String { header + curl + " \"$MODELDOCK_BASE_URL/" + path + "\"\n" }
        func json(_ payload: [String: Any], operation: String) -> String {
            let body = String(decoding: (try? ConnectionFiles.json(payload)) ?? Data("{}".utf8), as: UTF8.self)
            return header + curl + " --header 'Content-Type: application/json' --data-binary @- \"$MODELDOCK_BASE_URL" + operation + "\" <<'MODELDOCK_JSON'\n" + body + "\nMODELDOCK_JSON\n"
        }
        var values = [SolutionGatewayExample(id: "health", title: "检查组件状态", script: get("health")), .init(id: "models", title: "查看可用组件", script: get("models"))]
        for component in deployment.components {
            let role = component.role
            let script: String
            switch role {
            case .asr:
                script = header + """
                # Export MODELDOCK_AUDIO_FILE as the absolute path to an audio file.
                : "${MODELDOCK_AUDIO_FILE:?Set MODELDOCK_AUDIO_FILE to an audio file}"
                \(curl) --form-string 'model=asr' --form "file=@${MODELDOCK_AUDIO_FILE}" "$MODELDOCK_BASE_URL/audio/transcriptions"

                """
            case .tts:
                script = header + """
                # Base voice synthesis uses an audio reference and its transcript.
                : "${MODELDOCK_AUDIO_FILE:?Set MODELDOCK_AUDIO_FILE to the reference audio}"
                : "${MODELDOCK_REFERENCE_TEXT:?Set MODELDOCK_REFERENCE_TEXT to its transcript}"
                : "${MODELDOCK_SPEECH_TEXT:?Set MODELDOCK_SPEECH_TEXT to the text to speak}"
                python3 - <<'MODELDOCK_PY' | \(curl) --header 'Content-Type: application/json' --data-binary @- --output "${MODELDOCK_OUTPUT_FILE:-modeldock-speech.wav}" "$MODELDOCK_BASE_URL/audio/speech"
                import base64, json, os, pathlib
                audio = pathlib.Path(os.environ['MODELDOCK_AUDIO_FILE']).read_bytes()
                json.dump({'model': 'tts', 'input': os.environ['MODELDOCK_SPEECH_TEXT'],
                    'reference_text': os.environ['MODELDOCK_REFERENCE_TEXT'],
                    'reference_audio': base64.b64encode(audio).decode()}, __import__('sys').stdout)
                MODELDOCK_PY

                """
            case .vision:
                script = header + """
                # Export MODELDOCK_IMAGE_FILE as the absolute path to an image.
                : "${MODELDOCK_IMAGE_FILE:?Set MODELDOCK_IMAGE_FILE to an image}"
                python3 - <<'MODELDOCK_PY' | \(curl) --header 'Content-Type: application/json' --data-binary @- "$MODELDOCK_BASE_URL/chat/completions"
                import base64, json, mimetypes, os, pathlib, sys
                source = pathlib.Path(os.environ['MODELDOCK_IMAGE_FILE'])
                mime = mimetypes.guess_type(source.name)[0] or 'image/png'
                image = 'data:' + mime + ';base64,' + base64.b64encode(source.read_bytes()).decode()
                json.dump({'model': 'vision', 'messages': [{'role': 'user', 'content': [
                    {'type': 'text', 'text': 'Describe this image.'},
                    {'type': 'image_url', 'image_url': {'url': image}}]}], 'max_tokens': 512}, sys.stdout)
                MODELDOCK_PY

                """
            case .image:
                script = json(["model": "image", "prompt": "A quiet lakeside cabin at sunrise", "size": "1024x1024", "seed": 42, "n": 1, "response_format": "b64_json"], operation: role.gatewayOperation)
            case .text, .chat:
                var messages: [[String: String]] = []
                if role == .text { messages.append(["role": "system", "content": "Translate the user's text into \(deployment.draft.language). Return only the translation."]) }
                messages.append(["role": "user", "content": "Hello"])
                script = json(["model": role.gatewayModel, "messages": messages, "max_tokens": 512, "stream": false, "chat_template_kwargs": ["enable_thinking": false]], operation: role.gatewayOperation)
            }
            values.append(.init(id: role.gatewayModel, title: role.rawValue, script: script))
            if role == .image {
                values.append(.init(id: "image-to-image", title: "图生图", script: header + """
                # Upload one PNG, JPEG or WebP image. Higher strength redraws more.
                : "${MODELDOCK_IMAGE_FILE:?Set MODELDOCK_IMAGE_FILE to the reference image}"
                \(curl) --form-string 'model=image' --form "image=@${MODELDOCK_IMAGE_FILE}" --form-string 'prompt=A quiet lakeside cabin in winter' --form-string 'strength=0.75' --form-string 'size=1024x1024' --form-string 'response_format=b64_json' "$MODELDOCK_BASE_URL/images/edits"

                """))
            }
        }
        return values
    }
}

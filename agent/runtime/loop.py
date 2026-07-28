"""
AIRKit incident analysis agent — runtime loop.

Wires the SGLang-served GLM-5.2 endpoint (OpenAI-compatible API, provisioned
by infra/) to the two read-only MCP tool servers (clickhouse_tool,
qdrant_tool) and runs a standard tool-calling ReAct loop. Deliberately
minimal for the POC: no persistent conversation storage, no multi-agent
delegation, no write-capable tools. Those are later phases of the
playbook, not this one.
"""

import asyncio
import json
import os
from pathlib import Path

import httpx
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SGLANG_ENDPOINT = os.environ.get("AIRKIT_SGLANG_ENDPOINT", "http://localhost:3000/v1")
MODEL_NAME = os.environ.get("AIRKIT_MODEL_NAME", "GLM-5.2")
SYSTEM_PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "soc_analyst.md"
MAX_TOOL_ITERATIONS = 12  # hard ceiling so a confused loop can't run indefinitely

MCP_SERVERS = {
    "clickhouse_tool": StdioServerParameters(
        command="python3",
        args=[str(Path(__file__).parent / "mcp_servers" / "clickhouse_tool" / "server.py")],
    ),
    "qdrant_tool": StdioServerParameters(
        command="python3",
        args=[str(Path(__file__).parent / "mcp_servers" / "qdrant_tool" / "server.py")],
    ),
}


class AirkitAgent:
    """
    Thin orchestration wrapper. Connects to each configured MCP server,
    aggregates their tool manifests into the OpenAI-style tools list SGLang
    expects, and runs a bounded tool-calling loop against GLM-5.2.
    """

    def __init__(self) -> None:
        self.system_prompt = SYSTEM_PROMPT_PATH.read_text()
        self.http = httpx.AsyncClient(base_url=SGLANG_ENDPOINT, timeout=120.0)
        self._mcp_sessions: dict[str, ClientSession] = {}
        self._tool_to_server: dict[str, str] = {}

    async def __aenter__(self) -> "AirkitAgent":
        self._exit_stack_contexts = []
        for name, params in MCP_SERVERS.items():
            read, write = await stdio_client(params).__aenter__()
            session = await ClientSession(read, write).__aenter__()
            await session.initialize()
            self._mcp_sessions[name] = session
            tools = await session.list_tools()
            for tool in tools.tools:
                self._tool_to_server[tool.name] = name
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        for session in self._mcp_sessions.values():
            await session.__aexit__(*exc_info)
        await self.http.aclose()

    async def _openai_tools_schema(self) -> list[dict]:
        schema = []
        for name, session in self._mcp_sessions.items():
            tools = await session.list_tools()
            for tool in tools.tools:
                schema.append(
                    {
                        "type": "function",
                        "function": {
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": tool.inputSchema,
                        },
                    }
                )
        return schema

    async def _call_tool(self, tool_name: str, arguments: dict) -> str:
        server_name = self._tool_to_server.get(tool_name)
        if server_name is None:
            return json.dumps({"error": f"Unknown tool {tool_name!r}"})
        session = self._mcp_sessions[server_name]
        try:
            result = await session.call_tool(tool_name, arguments)
            return json.dumps(result.content)
        except Exception as exc:  # noqa: BLE001 — surfaced to the model as tool error, not raised
            return json.dumps({"error": str(exc)})

    async def run(self, user_message: str) -> str:
        messages = [
            {"role": "system", "content": self.system_prompt},
            {"role": "user", "content": user_message},
        ]
        tools = await self._openai_tools_schema()

        for _ in range(MAX_TOOL_ITERATIONS):
            response = await self.http.post(
                "/chat/completions",
                json={
                    "model": MODEL_NAME,
                    "messages": messages,
                    "tools": tools,
                    "tool_choice": "auto",
                },
            )
            response.raise_for_status()
            choice = response.json()["choices"][0]
            message = choice["message"]
            messages.append(message)

            tool_calls = message.get("tool_calls")
            if not tool_calls:
                return message.get("content", "")

            for call in tool_calls:
                fn = call["function"]
                args = json.loads(fn["arguments"])
                result = await self._call_tool(fn["name"], args)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": result,
                    }
                )

        return (
            "Reached the maximum number of tool-call iterations "
            f"({MAX_TOOL_ITERATIONS}) without a final answer. This usually "
            "means the query needs to be narrowed, or that intermediate "
            "results should be reviewed manually."
        )


async def main() -> None:
    import sys

    if len(sys.argv) < 2:
        print("Usage: loop.py '<question>'")
        raise SystemExit(1)

    question = sys.argv[1]
    async with AirkitAgent() as agent:
        answer = await agent.run(question)
        print(answer)


if __name__ == "__main__":
    asyncio.run(main())

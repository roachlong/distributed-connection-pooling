FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY EventLogsWorkflow.sln ./
COPY EventLogs.Domain/EventLogs.Domain.csproj EventLogs.Domain/
COPY EventLogs.Data/EventLogs.Data.csproj EventLogs.Data/
COPY EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj EventLogs.RequestGenerator/
COPY EventLogs.RequestProcessor/EventLogs.RequestProcessor.csproj EventLogs.RequestProcessor/

RUN dotnet restore EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj

COPY . .
RUN dotnet publish EventLogs.RequestGenerator/EventLogs.RequestGenerator.csproj -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/runtime:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "EventLogs.RequestGenerator.dll"]

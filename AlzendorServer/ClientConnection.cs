using Alzendor.Core.Utilities.Logger;
using System;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace Alzendor.Server
{
    public class ClientConnection
    {
        Socket clientSocket;
        string clientNumber;
        ILogger myLogger;
        GameState gameState;
        public ClientConnection(ILogger logger, GameState initialState)
        {
            gameState = initialState;
            myLogger = logger;
        }
        // ADD RETURN DATA
        // If returnedata != null, send it back to the client
        public void StartClient(Socket inClientSocket, string inClientNumber)
        {
            clientSocket = inClientSocket;
            clientNumber = inClientNumber;
            Thread ctThread = new Thread(DoChat);
            ctThread.Start();
        }
        private void DoChat()
        {
            byte[] bytesFrom;
            int requestCounter = 0;
            bool connected = true;
            NetworkStream stream = new NetworkStream(clientSocket);
            foreach(ServerObject serverObject in gameState.GetServerObjectList())
            {
                // TODO: send each object down stream to the client
            }
            while (connected)
            {
                try
                {
                    requestCounter++;
                    bytesFrom = new byte[1024];
                    stream.Read(bytesFrom);
                    string dataFromClient = Encoding.ASCII.GetString(bytesFrom);
                    myLogger.Log(LogLevel.Info, $">> From client {clientNumber}: {dataFromClient}");
                    string serverResponse = dataFromClient;
                    byte[] sendBytes = Encoding.ASCII.GetBytes(serverResponse);
                    stream.Write(sendBytes, 0, sendBytes.Length);
                }
                catch (SocketException)
                {
                    myLogger.Log(LogLevel.Info, $">> client({clientNumber}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    myLogger.Log(LogLevel.Error, $">> client({clientNumber}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }
    }
}

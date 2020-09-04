using AlzendorCore.Utilities.Actions;
using AlzendorCore.Utilities.DataTransfer;
using AlzendorCore.Utilities.Logger;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AlzendorClient
{
    public class ConnectionToServer
    {
        ILogger logger;
        NetworkStream networkStream;
        UserAction userAction = null;
        Socket server;
        int sleepDelay;
        byte[] fromServer;

        public ConnectionToServer(ILogger logger, string hostIP, int buffersize, int sleepDelay)
        {
            IPAddress ipAddress;
            IPEndPoint remoteEP;
            IPHostEntry host;
            this.sleepDelay = sleepDelay;
            this.logger = logger;
            fromServer = new byte[buffersize];

            try
            {
                host = Dns.GetHostEntry(hostIP);
                ipAddress = host.AddressList[0];
                remoteEP = new IPEndPoint(ipAddress, 11000);
                server = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                logger.Log(LogLevel.Info, $"Trying to connect to : {ipAddress.ToString()}");
                server.Connect(remoteEP);
                logger.Log(LogLevel.Info, $"Socket connected to {server.RemoteEndPoint.ToString()}");
                
            }
            catch (Exception exception)
            {
                logger.Log(LogLevel.Error, exception.Message);
            }
            Thread ioLoop = new Thread(IOLoop);
            ioLoop.Start();
        }
        public void SendAction(UserAction inputAction)
        {
            userAction = inputAction;
        }
        public void IOLoop()
        {
            try
            {
                networkStream = new NetworkStream(server);                

                while (true)
                {
                    Thread.Sleep(sleepDelay);
                    networkStream.ReadAsync(fromServer, 0, fromServer.Length);
                    byte[] incomingBytes = new byte[fromServer.Length];
                    Array.Copy(fromServer, 0, incomingBytes, 0, fromServer.Length);
                    Array.Clear(fromServer, 0, fromServer.Length);
                    if (incomingBytes != null && incomingBytes.Length > 0)
                    {
                        try
                        {
                            MessageAction inObject = JsonConvert.DeserializeObject<MessageAction>(Encoding.ASCII.GetString(incomingBytes));

                            if (inObject == null) {
                                //Console.WriteLine("IncomingObject is null");
                            }else if(inObject.Sender == "Morek"){
                                Console.WriteLine("Client Recieved|" + inObject.Message + "|From Server");
                            }
                        } catch (Exception e) {
                            Console.WriteLine(e.StackTrace);
                        }
                    }

                    if(userAction != null)
                    {                       
                        string serializedAction = JsonConvert.SerializeObject(userAction);
                        byte[] msg = Encoding.ASCII.GetBytes(serializedAction.ToCharArray());
                        networkStream.Write(msg, 0, msg.Length);                        
                        userAction = null;
                    }                    
                }
            }
            catch (ArgumentNullException argumentNullException)
            {
                logger.Log(LogLevel.Error, $"ArgumentNullException : {argumentNullException.ToString()}");
            }
            catch (SocketException socketException)
            {
                logger.Log(LogLevel.Error, $"SocketException : {socketException.ToString()}");
            }
            catch (Exception exception)
            {
                logger.Log(LogLevel.Error, $"Unexpected exception : {exception.ToString()}");
            }
            finally
            {
                server.Shutdown(SocketShutdown.Both);
                server.Close();
            }
        }        
    }
}

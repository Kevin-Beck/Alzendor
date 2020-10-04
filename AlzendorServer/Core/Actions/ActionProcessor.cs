using Alzendor.Core.Utilities.Logger;
using System;
using System.Collections.Generic;

namespace Alzendor.Server.Core.Actions
{
    public class ActionProcessor
    {
        public string Name { get; }
        private readonly List<ActionObject> objectsToProcess = new List<ActionObject>();
        ILogger logger;

        public ActionProcessor(ILogger log, List<GameElement> gameElements, Dictionary<string, ConnectionToClient> clients)
        {
            logger = log;
        }
        public void Add(ActionObject objectToAdd)
        {
            if(objectToAdd != null)
            {
                objectsToProcess.Add(objectToAdd);
            }
        }
        public void Process()
        {
            while(objectsToProcess.Count > 0)
            {
                try
                {
                    var curObject = objectsToProcess[0];
                    Console.WriteLine(curObject.Type);
                    if (curObject.Type == ActionType.MESSAGE)
                    {
                        var messageObject = (MessageAction)curObject;
                        if (messageObject.Sender == "kevin")
                        {
                            // TODO FIX THIS
                            logger.Log(LogLevel.Info, $"kevin sent a message");
                        }
                    }
                    objectsToProcess.RemoveAt(0);
                }catch(Exception e)
                {
                    logger.Log(LogLevel.Error, $"{e.Message}\n\n{e.StackTrace}\n\n");
                }

            }
        }
    }
}

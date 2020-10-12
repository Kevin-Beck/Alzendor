using Alzendor.Server.Core.Actions.Edit;
using log4net;
using System;
using System.Collections.Generic;

namespace Alzendor.Server.Core.Actions
{
    public class ActionProcessor
    {
        public string Name { get; }
        private static ILog logger;
        private readonly List<ActionObject> actionsToProcess = new List<ActionObject>();
        private readonly ServerMain server;
        private readonly Dictionary<ActionType, Func<string, string>> thing = new Dictionary<ActionType, Func<string, string>>();

        // this is a function to pass in to thing

        private Func<string, string> testingThing = (firststring) =>
        {
            // todo create a static class which will hold these functions, map the action processor pieces to this map, then hit the map to return the
            // function and process the action

            return "this is the return value";
        };

        private string Function2(string thing)
        {
            return "this is the return";
        }

        public ActionProcessor(ILog log, ServerMain serverObject)
        {
            logger = log;
            thing.Add(ActionType.CONSUME, testingThing); // todo fix this
            thing.Add(ActionType.LOGIN, Function2);
            server = serverObject;
        }
        public void RemoveUser(string username)
        {
            server.users.Remove(username);
        }
        public void Add(ActionObject objectToAdd)
        {
            if(objectToAdd != null)
            {
                actionsToProcess.Add(objectToAdd);
                Process();
            }
        }
        public void Process()
        {
            while(actionsToProcess.Count > 0)
            {
                try
                {
                    var curObject = actionsToProcess[0];
                    logger.Info($"Processing {curObject.Type}");
                    if (curObject.Type == ActionType.MESSAGE)
                    {
                        MessageAction messageAction = (MessageAction)curObject;
                        if (messageAction.MessageType == MessageType.CHANNEL)
                        {
                            if(server.channels.ContainsKey(messageAction.Receiver))
                            {
                                server.channels.TryGetValue(messageAction.Receiver, out ChannelElement channel);
                                if (channel != null)
                                {
                                    logger.Info($"Adding message to {channel.ChannelName} from {messageAction.Sender}");
                                    channel.AddMessage(messageAction);
                                }
                                else
                                {
                                    logger.Warn($"Channel {channel.ChannelName} was in channels list, but is null");
                                }

                            }else
                            {
                                logger.Info($"Channel {messageAction.Receiver} was not found in channels list.");
                                // return message to sender
                                server.users.TryGetValue(messageAction.Sender, out ConnectionToClient sender);
                                if(sender != null)
                                {
                                    logger.Info($"{messageAction.Sender} found, sending them ");
                                    sender.Send("Nothing here with that name!");
                                }
                                else
                                {
                                    logger.Warn("Sender is not found in users....");
                                }
                            }
                        }
                        else
                        {
                            // TODO other kinds of messages
                        }
                    }
                    else if(curObject.Type == ActionType.SUBSCRIBE)
                    {
                        SubscribeAction subscribeAction = (SubscribeAction)curObject;
                        if(subscribeAction.TypeOfSubscription == SubscriptionType.CHANNEL)
                        {
                            server.channels.TryGetValue(subscribeAction.GameElementName, out ChannelElement channel);
                            if(channel != null && ((channel.IsPublic) || (channel.ChannelOwner == subscribeAction.Sender)))
                            {
                                server.users.TryGetValue(subscribeAction.Sender, out ConnectionToClient client);
                                if(client != null)
                                {
                                    channel.AddSubscriber(client);                                    
                                    logger.Info($"{subscribeAction.Sender} has subscribed to channel: {channel.ChannelName}");
                                }
                                else
                                {
                                    logger.Warn($"Client Connection not found for user: {subscribeAction.Sender}, unable to subscribe to channel");
                                }
                            }
                            else
                            {
                                // return to request with unable to subscribe
                                server.users.TryGetValue(subscribeAction.Sender, out ConnectionToClient sender);
                                if (sender != null)
                                {
                                    sender.Send($"Could not find anything to listen to by the name: {subscribeAction.Name}. It may not be public.");
                                    logger.Info($"Returning to {subscribeAction.Sender}, no channel found with name {subscribeAction.Name}.");
                                }
                            }
                        }
                    }else if(curObject.Type == ActionType.CREATE)
                    {
                        CreateAction createAction = (CreateAction)curObject;
                        if(createAction.TypeOfObjectToCreate == "channel")
                        {
                            var name = createAction.NameOfCreatedObject;
                            server.channels.TryGetValue(name, out ChannelElement channel);
                            if(channel == null)
                            {
                                var createdChannel = new ChannelElement(createAction.NameOfCreatedObject, createAction.Sender);
                                server.channels.Add(createAction.NameOfCreatedObject, createdChannel);
                                logger.Info($"Channel: {createAction.NameOfCreatedObject} has been created by {createAction.Sender}");
                                server.users.TryGetValue(createAction.Sender, out ConnectionToClient sender);
                                if (sender != null)
                                {
                                    createdChannel.AddSubscriber(sender);
                                }
                            }
                            else
                            {
                                // return to request with unable to subscribe
                                server.users.TryGetValue(createAction.Sender, out ConnectionToClient sender);
                                if(sender != null)
                                {
                                    sender.Send("Channel already exists! If its public, you can listen in by saying 'Listen to <channel>'");
                                }
                                else
                                {
                                    logger.Warn("User who sent create channel command no longer exists.");
                                }
                            }
                        }
                    }else if(curObject.Type == ActionType.EDIT)
                    {
                        EditAction editAction = (EditAction)curObject;
                        if(editAction.TypeOfEdit == EditType.CHANNEL && editAction.Component == "name")
                        {
                            server.channels.TryGetValue(editAction.ElementToEdit, out ChannelElement channel);
                            if(channel != null)
                            {
                                if(channel.ChannelOwner == editAction.Sender && !server.channels.ContainsKey(editAction.NewValue))
                                {
                                    channel.ChannelName = editAction.NewValue;
                                } // todo create the logging for this, create the process for telling everyone its been renamed
                                // todo 
                            }
                        }
                    }
                }catch(Exception e)
                {
                    logger.Error($"While processing ActionObject: {actionsToProcess[0].ToString()}\n\n{e.Message}\n\n{e.StackTrace}\n\n");
                }
                actionsToProcess.RemoveAt(0);
            }
        }
    }
}

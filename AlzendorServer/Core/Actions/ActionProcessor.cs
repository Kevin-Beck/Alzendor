using AlzendorCore.Utilities;
using AlzendorServer.Core.Elements;
using AlzendorServer.Elements;
using log4net;
using StackExchange.Redis;
using System;
using System.Reflection;

namespace AlzendorServer.Core.Actions
{
    public class ActionProcessor
    {
        private static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        // TODO map the functions for each action to a static class and pass each one into a dictionary, then just retrieve the function needed and pass the object in
        //private readonly Dictionary<ActionType, Func<string, string>> thing = new Dictionary<ActionType, Func<string, string>>();
        readonly IDatabase database;
        readonly ISubscriber subscriber; // DO NOT USE THE SUBSCRIBER just dont touch it. only subscribe using the SUbscribeAction.
        private ConnectionToClient connection;
        public ActionProcessor(IDatabase data, ISubscriber sub, ConnectionToClient con)
        {
            database = data;
            subscriber = sub; // sub should only be used to subscribe and unsubscribe from things, otherwise it just receives messages.
            connection = con;
        }

        public void Process(ActionObject curObject)
        {
            if (curObject == null)
            {
                return;
            }
            try
            {
                logger.Info($"Processing {curObject.ActionType}");
                if (curObject.ActionType == ActionType.MESSAGE)
                {
                    MessageAction messageAction = (MessageAction)curObject;
                    logger.Debug($"------>{messageAction.ElementType}:{messageAction.ElementName}<-------");
                    var targetName = $"{messageAction.ElementType}:{messageAction.ElementName}";
                    if (database.KeyExists(targetName))
                    {
                        logger.Info($"Key exists for {targetName}, getting ChannelElement");
                        ChannelElement channelElement = Objectifier.DeStringify<ChannelElement>(database.StringGet(targetName));

                        // If the sender is subscribed to the channel or the channel is a person who is logged in, they can send the message
                        if (channelElement.subscribers.Contains(messageAction.Sender))
                        {
                            logger.Info($"{messageAction.Sender} was found in the ChannelElement's Subscribers list");
                            // TODO make a lightweight chat element for the following publishing
                            if (database.Publish(targetName, Objectifier.Stringify(new MessageAction(messageAction.Sender, messageAction.ElementName, messageAction.Message))) != 0)
                            {
                                logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName}");
                            }
                            else
                            {
                                logger.Warn($"{messageAction.Sender} sent message to {messageAction.ElementName} but no one was found by that name");
                            }
                        }else if (database.SetContains("loggedIn", messageAction.ElementName))
                        {
                            logger.Info($"{messageAction.Sender} was not found in the ChannelElement's Subscribers list, but the target '{messageAction.ElementName}' is in the set 'loggedIn'");
                            // TODO make a lightweight chat element for the following publishing
                            if (database.Publish(targetName, Objectifier.Stringify(new MessageAction(messageAction.Sender, messageAction.ElementName, messageAction.Message))) != 0)
                            {
                                logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName}");
                            }
                            else
                            {
                                logger.Warn($"{messageAction.Sender} sent message to {messageAction.ElementName} but no one was found by that name");
                            }
                        }
                        else
                        {
                            logger.Info($"{messageAction.Sender} is not in the channel's subscribers list, and the target {messageAction.ElementName} is not in the loggedIn set");
                        }
                    }               
                }
                else if (curObject.ActionType == ActionType.SUBSCRIBE) // HEY THE ONLY WAY TO SUBSCRIBE IS THROUGH A SUBSCRIBE ACTION
                {
                    SubscribeAction subscribeAction = (SubscribeAction)curObject;
                    logger.Info($"{subscribeAction.Sender} subscribing to element of type: {subscribeAction.ElementType} and name {subscribeAction.ElementName}");
                    if (subscribeAction.ElementType == ElementType.CHANNEL)
                    {
                        var targetName = $"{subscribeAction.ElementType}:{subscribeAction.ElementName}";
                        if (database.KeyExists(targetName))
                        {
                            logger.Info($"Database contains a key for {targetName}, fetching ChannelElement");
                            ChannelElement channel = Objectifier.DeStringify<ChannelElement>(database.StringGet(targetName));
                            if (channel.subscribers.Contains(subscribeAction.Sender))
                            {
                                logger.Info($"{subscribeAction.Sender} is subscribed already? {channel.subscribers.Contains(subscribeAction.Sender)}");
                                database.Publish(targetName, "you're already subscribed to this channel"); // todo make a lightweight return object
                                return;
                            }else if(!channel.IsPrivate || subscribeAction.Sender == subscribeAction.ElementName) // the channel is public, or you're subscribing to your own initial channel
                            {
                                logger.Info($"{subscribeAction.Sender} is allowed to subscribe to {channel.ChannelName}");
                                channel.AddSubscriber(subscribeAction.Sender.ToLower());
                                database.StringSet(targetName, Objectifier.Stringify(channel));

                                subscriber.Subscribe(targetName, (channel, message) =>
                                {
                                    connection.Send($"{channel}|{message}");
                                });
                                logger.Info($"{subscribeAction.Sender} successfully subscribed");
                                database.Publish(
                                    $"{targetName}", Objectifier.Stringify( // TODO create a class for message objects that are lighter weight to send to clients
                                    new MessageAction(
                                        "ChannelAlert", // todo rename this to some kind of object that isnt the same as message action
                                        subscribeAction.ElementName,
                                        $"{subscribeAction.Sender} has joined {subscribeAction.ElementName}"
                                        )
                                    ));
                            }
                        }
                        else
                        {
                            logger.Debug($"Could not subscribe to {subscribeAction.ElementType} named {subscribeAction.ElementName} as it does not exist");
                            //TODO return a non exist, perhaps you want to CREATE it message
                        }                        
                    }
                }
                else if (curObject.ActionType == ActionType.CREATE)
                {
                    CreateAction createAction = (CreateAction)curObject;
                    logger.Info($"{createAction.Sender} wants to create {createAction.ElementType} with name '{createAction.ElementName}'");
                    if (createAction.ElementType == ElementType.CHANNEL)
                    {
                        var name = $"{createAction.ElementType}:{createAction.ElementName}";
                        if (!database.KeyExists(name))
                        {
                            var channel = new ChannelElement(createAction.ElementName, createAction.Sender, false);
                            // Special case for people's personal channels:
                            if (createAction.ElementName == createAction.Sender)
                            {
                                channel.IsPrivate = true;
                                channel.ChannelOwner = "admin";
                            }

                            database.StringSet(name, Objectifier.Stringify(channel));
                            Process(new SubscribeAction(createAction.Sender, ElementType.CHANNEL, createAction.ElementName));
                            database.Publish(name, $"The {createAction.ElementName} channel has been created successfully!");
                            logger.Info($"The {createAction.ElementName} channel has been created successfully by {createAction.Sender}");
                        }
                        else
                        {
                            logger.Info("Channel Creation failed -> Already a channel with that name");
                            // TODO return with a "channel already exists with that name"
                        }
                    }
                    else
                    {
                        // TODO other kinds of create
                    }
                }
                else if (curObject.ActionType == ActionType.CHANGE)
                {
                    
                }
            }
            catch (Exception e)
            {
                logger.Error($"While processing ActionObject: {curObject.ToString()}\n\n{e.Message}\n\n{e.StackTrace}\n\n");
            }
        }
    }
}

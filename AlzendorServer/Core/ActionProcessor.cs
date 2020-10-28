using AlzendorCore.Utilities;
using AlzendorServer.Actions;
using AlzendorServer.DataTransfer;
using AlzendorServer.Elements;
using log4net;
using StackExchange.Redis;
using System;
using System.Reflection;

namespace AlzendorServer.Core
{
    public class ActionProcessor
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private readonly IDatabase database;
        private readonly ISubscriber subscriber;
        private readonly ConnectionToClient connection;
        public ActionProcessor(IDatabase data, ISubscriber sub, ConnectionToClient con)
        {
            database = data;
            subscriber = sub; // sub should only be used to subscribe and unsubscribe from things, otherwise it just receives messages.
            connection = con;
        }
        private string GetNamingConvention(ElementType type, string elementName)
        {
            return $"{type}:{elementName}";
        }
        private long SendMessageToChannelFromSender(string sender, string receiver, string message)
        {
            return database.Publish(GetNamingConvention(ElementType.CHANNEL, receiver), Objectifier.Stringify(new ChatData(sender, receiver, message)));
        }
        private long SendServerMessageToChannel(ServerMessageType type, string channelName, string message)
        {
            return database.Publish(GetNamingConvention(ElementType.CHANNEL, channelName), Objectifier.Stringify(new ChatData(type.ToString(), connection.ClientID, message)));
        }
        private bool GetElementFromDatabase<T>(string name, ElementType type, out T element)
        {
            element = default;
            if (database.KeyExists(GetNamingConvention(type, name)))
            {
                try
                {
                    element = Objectifier.DeStringify<T>(database.StringGet(GetNamingConvention(type, name)));
                    return true;
                } catch (Exception e)
                {
                    logger.Warn("Object could not be cast into requested element" + e.ToString());
                }
            }
            else
            {
                logger.Warn($"No key exists in the database for {GetNamingConvention(type, name)}");
            }
            return false;
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
                    ProcessMessageAction(messageAction);
                }
                else if (curObject.ActionType == ActionType.SUBSCRIBE)
                {
                    SubscribeAction subscribeAction = (SubscribeAction)curObject;
                    ProcessSubscribeAction(subscribeAction);
                }
                else if (curObject.ActionType == ActionType.CREATE)
                {
                    CreateAction createAction = (CreateAction)curObject;
                    ProcessCreateAction(createAction);
                }
                else if (curObject.ActionType == ActionType.CHANGE)
                {
                    ChangeAction changeAction = (ChangeAction)curObject;
                    ProcessChangeAction(changeAction);
                }
            }
            catch (Exception e)
            {
                logger.Error($"While processing ActionObject: {curObject.ToString()}\n\n{e.Message}\n\n{e.StackTrace}\n\n");
            }
        }
        private void ProcessChangeAction(ChangeAction changeAction)
        {
            logger.Info($"{changeAction.Sender} is trying to change {changeAction.ElementType} {changeAction.ElementName}'s property {changeAction.ElementProperty} to {changeAction.NewElementPropertyValue}");
            if(changeAction.ElementType == ElementType.CHANNEL)
            {
                if(GetElementFromDatabase(changeAction.ElementName, changeAction.ElementType, out ChannelElement channel))
                {
                    logger.Info($"Channel '{changeAction.ElementName}' has been found in database. Preparing to change property.");
                    if(channel.ChannelOwner != changeAction.Sender)
                    {
                        SendServerMessageToChannel(ServerMessageType.Warning, changeAction.Sender, $"You cannot change the channel's name as you are not the owner");
                        return;
                    }
                    if(changeAction.ElementProperty == "privacy")
                    {
                        if (changeAction.NewElementPropertyValue == "public")
                        {
                            channel.IsPrivate = false;
                            SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to public.");
                            database.StringSet(GetNamingConvention(ElementType.CHANNEL, changeAction.ElementName), Objectifier.Stringify(channel));
                        }
                        else if (changeAction.NewElementPropertyValue == "private")
                        {
                            channel.IsPrivate = true;
                            SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to private.");
                            database.StringSet(GetNamingConvention(ElementType.CHANNEL, changeAction.ElementName), Objectifier.Stringify(channel));
                        }
                        else
                        {
                            SendServerMessageToChannel(ServerMessageType.Warning, changeAction.Sender, $"Unrecognized privacy setting: {changeAction.NewElementPropertyValue}");
                        }
                    }
                }
            }
        }
        private void ProcessCreateAction(CreateAction createAction)
        {
            logger.Info($"{createAction.Sender} wants to create {createAction.ElementType} with name '{createAction.ElementName}'");
            if (createAction.ElementType == ElementType.CHANNEL)
            {
                if (GetElementFromDatabase(createAction.ElementName, createAction.ElementType, out ChannelElement foundChannel))
                {
                    logger.Info("Channel Creation failed -> Already a channel with that name");
                    SendServerMessageToChannel(ServerMessageType.Warning, createAction.Sender, "That channel already exists!");
                }
                else
                {
                    ChannelElement channel = new ChannelElement(createAction.ElementName, createAction.Sender, false);
                    database.StringSet(GetNamingConvention(ElementType.CHANNEL, createAction.ElementName), Objectifier.Stringify(channel));
                    logger.Info($"The {createAction.ElementName} channel has been created successfully by {createAction.Sender}");
                    SendServerMessageToChannel(ServerMessageType.Info, createAction.Sender, $"The {createAction.ElementName} channel has been created successfully!");
                    Process(new SubscribeAction(createAction.Sender, ElementType.CHANNEL, createAction.ElementName));
                    if (createAction.ElementName == createAction.Sender)
                    {
                        channel.IsPrivate = true;
                        channel.ChannelOwner = "admin";
                        database.StringSet(GetNamingConvention(ElementType.CHANNEL, createAction.ElementName), Objectifier.Stringify(channel));
                    }
                }
            }
            else
            {
                // TODO other kinds of create
            }
        }
        private void ProcessSubscribeAction(SubscribeAction subscribeAction)
        {
            logger.Info($"{subscribeAction.Sender} subscribing to element of type: {subscribeAction.ElementType} and name {subscribeAction.ElementName}");
            if (subscribeAction.ElementType == ElementType.CHANNEL)
            {
                if (GetElementFromDatabase(subscribeAction.ElementName, subscribeAction.ElementType, out ChannelElement channel))
                {
                    logger.Info($"Retrieved Channel: {channel.ChannelName} from database");
                    if (channel.subscribers.Contains(subscribeAction.Sender))
                    {
                        logger.Info($"{subscribeAction.Sender} is subscribed already? {channel.subscribers.Contains(subscribeAction.Sender)}");
                        SendServerMessageToChannel(ServerMessageType.Warning, subscribeAction.Sender, "You're already subscribed to that channel");
                        return;
                    }
                    else if (!channel.IsPrivate || subscribeAction.Sender == subscribeAction.ElementName) // the channel is public, or you're subscribing to your own initial channel
                    {
                        logger.Info($"{subscribeAction.Sender} is allowed to subscribe to {channel.ChannelName}");
                        channel.AddSubscriber(subscribeAction.Sender.ToLower());

                        database.StringSet(GetNamingConvention(ElementType.CHANNEL, subscribeAction.ElementName), Objectifier.Stringify(channel));

                        subscriber.Subscribe(GetNamingConvention(ElementType.CHANNEL, subscribeAction.ElementName), (channel, message) =>
                        {
                            connection.Send($"{channel}|{message}");
                        });

                        logger.Info($"{subscribeAction.Sender} successfully subscribed");
                        SendServerMessageToChannel(ServerMessageType.Info, subscribeAction.ElementName, $"{subscribeAction.Sender} has joined {subscribeAction.ElementName}");
                    }
                    else
                    {
                        logger.Info($"{subscribeAction.Sender} is not permitted to subscribe to {subscribeAction.ElementType} + {subscribeAction.ElementName}");
                        SendServerMessageToChannel(ServerMessageType.Warning, subscribeAction.Sender, $"You are not permitted to subscribe to {subscribeAction.ElementType} {subscribeAction.ElementName}");
                    }
                }
                else
                {
                    logger.Debug($"Could not subscribe to {subscribeAction.ElementType} {subscribeAction.ElementName} as it was not retreived from database");
                    database.Publish($"CHANNEL:{subscribeAction.Sender}", $"There is no channel to subscribe to with the name {subscribeAction.ElementName}, perhaps you want to CREATE it");
                }
            }
        }
        private void ProcessMessageAction(MessageAction messageAction)
        {
            var targetName = GetNamingConvention(messageAction.ElementType, messageAction.ElementName);
            if (database.KeyExists(targetName))
            {
                logger.Info($"Key exists for {targetName}, getting ChannelElement");
                ChannelElement channelElement = Objectifier.DeStringify<ChannelElement>(database.StringGet(targetName));

                if (channelElement.subscribers.Contains(messageAction.Sender) || database.SetContains("loggedIn", messageAction.ElementName))
                {
                    logger.Info($"Message permitted: {messageAction.Sender}");
                    if (SendMessageToChannelFromSender(messageAction.Sender, messageAction.ElementName, messageAction.Message) != 0)
                    {
                        logger.Info($"{messageAction.Sender} successfully sent message to {messageAction.ElementName}");
                    }
                    else
                    {
                        logger.Warn($"{messageAction.Sender} tried to send message to {messageAction.ElementName} but no one was found by that name");
                    }
                }
                else
                {
                    logger.Info($"{messageAction.Sender}'s message is not permitted, sender not in subscribers for target, or target is not online");
                    SendServerMessageToChannel(ServerMessageType.Warning, messageAction.Sender, "Sorry, theres nothing to tell by that name.");
                }
            }
            else
            {
                SendServerMessageToChannel(ServerMessageType.Warning, messageAction.Sender, "Sorry, theres nothing to tell by that name.");
            }
        }
    }
}

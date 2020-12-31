using Core.Utilities;
using Server.Actions;
using Server.DataTransfer;
using Server.Elements;
using log4net;
using StackExchange.Redis;
using System;
using System.Reflection;
using Server.Database;

namespace Server.Base
{
    public class ActionProcessor
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private IDatabaseWrapper storage;
        private ConnectionToClient connection;
        public ActionProcessor(IDatabaseWrapper storage, ConnectionToClient con)
        {
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
                else if(curObject.ActionType == ActionType.LOGIN)
                {
                    LogInAction logInAction = (LogInAction)curObject;
                    ProcessLogInAction(logInAction);
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
                if(storage.GetElementFromDatabase(changeAction.ElementName, changeAction.ElementType, out ChannelElement channel))
                {
                    logger.Info($"Channel '{changeAction.ElementName}' has been found in database. Preparing to change property.");
                    if(channel.ChannelOwner != changeAction.Sender)
                    {
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, changeAction.Sender, $"You cannot change the channel's name as you are not the owner");
                        return;
                    }
                    if(changeAction.ElementProperty == "privacy")
                    {
                        if (changeAction.NewElementPropertyValue == "public")
                        {
                            channel.IsPrivate = false;
                            storage.SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to public.");
                            storage.AddElementToDatabase<ChannelElement>(channel);
                        }
                        else if (changeAction.NewElementPropertyValue == "private")
                        {
                            channel.IsPrivate = true;
                            storage.SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to private.");
                            storage.AddElementToDatabase<ChannelElement>(channel);
                        }
                        else
                        {
                            storage.SendServerMessageToChannel(ServerMessageType.Warning, changeAction.Sender, $"Unrecognized privacy setting: {changeAction.NewElementPropertyValue}");
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
                if (storage.GetElementFromDatabase(createAction.ElementName, createAction.ElementType, out ChannelElement foundChannel))
                {
                    logger.Info("Channel Creation failed -> Already a channel with that name");
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, createAction.Sender, "That channel already exists!");
                }
                else
                {
                    ChannelElement channel = new ChannelElement(createAction.ElementName, createAction.Sender, false);
                    storage.AddElementToDatabase<ChannelElement>(channel);
                    logger.Info($"The {createAction.ElementName} channel has been created successfully by {createAction.Sender}");
                    storage.SendServerMessageToChannel(ServerMessageType.Info, createAction.Sender, $"The {createAction.ElementName} channel has been created successfully!");
                    Process(new SubscribeAction(createAction.Sender, ElementType.CHANNEL, createAction.ElementName));
                    if (createAction.ElementName == createAction.Sender)
                    {
                        channel.IsPrivate = true;
                        channel.ChannelOwner = "admin";
                        storage.AddElementToDatabase<ChannelElement>(channel);
                    }
                }
            }
            else if(createAction.ElementType == ElementType.PLAYER)
            {
                
            }
        }
        private void ProcessSubscribeAction(SubscribeAction subscribeAction)
        {
            logger.Info($"{subscribeAction.Sender} subscribing to element of type: {subscribeAction.ElementType} and name {subscribeAction.ElementName}");
            if (subscribeAction.ElementType == ElementType.CHANNEL)
            {
                if (storage.GetElementFromDatabase(subscribeAction.ElementName, subscribeAction.ElementType, out ChannelElement channel))
                {
                    logger.Info($"Retrieved Channel: {channel.ChannelName} from database");
                    if (channel.subscribers.Contains(subscribeAction.Sender))
                    {
                        logger.Info($"{subscribeAction.Sender} is subscribed already? {channel.subscribers.Contains(subscribeAction.Sender)}");
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, subscribeAction.Sender, "You're already subscribed to that channel");
                        return;
                    }
                    else if (!channel.IsPrivate || subscribeAction.Sender == subscribeAction.ElementName) // the channel is public, or you're subscribing to your own initial channel
                    {
                        logger.Info($"{subscribeAction.Sender} is allowed to subscribe to {channel.ChannelName}");
                        channel.AddSubscriber(subscribeAction.Sender);

                        storage.Subscribe<ChannelElement>(channel, connection);

                        logger.Info($"{subscribeAction.Sender} successfully subscribed");
                        storage.SendServerMessageToChannel(ServerMessageType.Info, subscribeAction.ElementName, $"{subscribeAction.Sender} has joined {subscribeAction.ElementName}");
                    }
                    else
                    {
                        logger.Info($"{subscribeAction.Sender} is not permitted to subscribe to {subscribeAction.ElementType} + {subscribeAction.ElementName}");
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, subscribeAction.Sender, $"You are not permitted to subscribe to {subscribeAction.ElementType} {subscribeAction.ElementName}");
                    }
                }
                else
                {
                    logger.Debug($"Could not subscribe to {subscribeAction.ElementType} {subscribeAction.ElementName} as it was not retreived from database");
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, subscribeAction.Sender, $"There is no channel to subscribe to with the name {subscribeAction.ElementName}, perhaps you want to CREATE it");
                }
            }
        }
        private void ProcessMessageAction(MessageAction messageAction)
        {

            var targetName = storage.GetNamingConvention(messageAction.ElementType, messageAction.ElementName);
            storage.GetElementFromDatabase<ChannelElement>(messageAction.ElementName, messageAction.ElementType, out ChannelElement channel);
            if (channel != null)
            {
                if (channel.subscribers.Contains(messageAction.Sender))
                {
                    logger.Info($"Message permitted: {messageAction.Sender}");
                    if (storage.SendMessageToChannelFromSender(messageAction.Sender, messageAction.ElementName, messageAction.Message) != 0)
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
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, messageAction.Sender, "Sorry, theres nothing to tell by that name.");
                }
            }
            else
            {
                storage.SendServerMessageToChannel(ServerMessageType.Warning, messageAction.Sender, "Sorry, theres nothing to tell by that name.");
            }
        }
        private bool ProcessLogInAction(LogInAction logInAction)
        {
            if(logInAction.CurrentStep == LogInStatus.RequestingSalt)
            {
                
                // get the user object from redis, get the salt from the user, send the salt back to the user
                return true;
            }else if(logInAction.CurrentStep == LogInStatus.RequestingConfirmation)
            {
                // get the user object from redis, compare the logInData to the salted password stored
                // if they are equal the user has entered the correct password
                return true;
                // else return false
            }else if(logInAction.CurrentStep == LogInStatus.LoggedIn)
            {
                // get the user object from redis, send all the channel subscribe commands to resub to the channels
                // put the player in the correct space/square and return the inventory objects to player
            }
            return false;
        }
    }
}

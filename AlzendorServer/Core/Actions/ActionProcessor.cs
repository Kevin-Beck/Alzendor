using AlzendorCore.Utilities;
using AlzendorServer.Core.Elements;
using AlzendorServer.Elements;
using log4net;
using StackExchange.Redis;
using System;
using System.Collections.Generic;

namespace AlzendorServer.Core.Actions
{
    public class ActionProcessor
    {
        private static ILog logger;
        // TODO map the functions for each action to a static class and pass each one into a dictionary, then just retrieve the function needed and pass the object in
        //private readonly Dictionary<ActionType, Func<string, string>> thing = new Dictionary<ActionType, Func<string, string>>();
        readonly IDatabase database;
        readonly ISubscriber subscriber; // DO NOT USE THE SUBSCRIBER just dont touch it. only subscribe using the SUbscribeAction.
        private ConnectionToClient connection;
        public ActionProcessor(ILog log, IDatabase data, ISubscriber sub, ConnectionToClient con)
        {
            logger = log;
            database = data;
            subscriber = sub; // sub should only be used to subscribe and unsubscribe from things, otherwise it just receives messages.
            connection = con;
        }
        public void RemoveUser(string username)
        {
            database.KeyDelete("user:" + username);
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
                    if (database.Publish($"{messageAction.ElementType}:{messageAction.ElementName}", Objectifier.Stringify(messageAction)) == 0)
                    {
                        logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName} but no one was found by that name");
                        database.Publish($"{ElementType.CHANNEL}:{messageAction.Sender}", Objectifier.Stringify(new MessageAction("ServerWarning", messageAction.Sender, "There was no recipient by that name")));
                    }
                    else
                    {
                        logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName}");
                    }                 
                }
                else if (curObject.ActionType == ActionType.SUBSCRIBE) // HEY THE ONLY WAY TO SUBSCRIBE IS THROUGH A SUBSCRIBE ACTION
                {
                    SubscribeAction subscribeAction = (SubscribeAction)curObject;
                    if (subscribeAction.ElementType == ElementType.CHANNEL)
                    {
                        if (database.KeyExists($"{subscribeAction.ElementType}:{subscribeAction.ElementName}"))
                        {
                            subscriber.Subscribe($"{subscribeAction.ElementType}:{subscribeAction.ElementName}", (channel, message) =>
                            {
                                connection.Send($"{channel}|{message}");
                            });
                            database.Publish(
                                $"{subscribeAction.ElementType}:{subscribeAction.ElementName}", Objectifier.Stringify(
                                new MessageAction(
                                    "ChannelAlert", // rename this to some kind of object that isnt the same as message action
                                    subscribeAction.ElementName,
                                    $"{subscribeAction.Sender} has joined {subscribeAction.ElementName}"
                                    )
                                ));

                            // TODO return a success message to sender
                            // for attack
                            // kevin attack will with kick
                            // get user:target -> position health level data -> deserialize into targetObject
                            // get user:me -> position health level data -> deserialize int userObject
                            // userObject.getAttack(object.elementName).attack(targetObject.health)
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
                    if (createAction.ElementType == ElementType.CHANNEL)
                    {
                        var name = $"{createAction.ElementType}:{createAction.ElementName}";
                        if (!database.KeyExists(name))
                        {
                            // create a channel element, set the conditions to defaults and store it in database
                            // subscribe to that channel
                            database.StringSet(name, true); // todo figure out what to do with these channels
                            Process(new SubscribeAction(createAction.Sender, ElementType.CHANNEL, createAction.ElementName));
                            database.Publish(name, $"The {createAction.ElementName} channel has been created successfully!");
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
                    // todo, to change a channel we'll need to store the entire channel object with extra data, not just use the pub/sub channels
                    // so we will see if the channel exists then we will retrieve it and determine who owns it and if its public etc. this will require more involvement
                    // as we will no longer be able to depend on the super straight forward pubsub
                    // if(contains key channel:whatever)
                    // get the value from that key, that value will be an object that can be destringified and checked. Here we can set the owners tag and publicity then re-store it
                    // back in redis as the object, there is documentation about how to store these kidns of things with parameters online somewhere
                    // If you're accessing just a single element of the object you'll want to store it as pieces, but if you're always pulling the entire object you might as well 
                    // just json it all and store it.
                }
            }
            catch (Exception e)
            {
                logger.Error($"While processing ActionObject: {curObject.ToString()}\n\n{e.Message}\n\n{e.StackTrace}\n\n");
            }
        }
    }
}

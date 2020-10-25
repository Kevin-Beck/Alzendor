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
        public string Name { get; }
        private static ILog logger;
        // TODO map the functions for each action to a static class and pass each one into a dictionary, then just retrieve the function needed and pass the object in
        //private readonly Dictionary<ActionType, Func<string, string>> thing = new Dictionary<ActionType, Func<string, string>>();
        readonly IDatabase database;
        readonly ISubscriber subscriber;
        public ActionProcessor(ILog log, IDatabase data, ISubscriber sub)
        {
            logger = log;
            database = data;
            subscriber = sub; // sub should only be used to subsscribe and unsubscribe from things, otherwise it just receives messages.
        }
        public void RemoveUser(string username)
        {
            database.KeyDelete("user:" + username);
        }

        public void Process(ActionObject curObject)
        {
            try
            {
                logger.Info($"Processing {curObject.ActionType}");
                if (curObject.ActionType == ActionType.MESSAGE)
                {
                    MessageAction messageAction = (MessageAction)curObject;
                    if (database.Publish("channel:" + messageAction.ElementName, Objectifier.Stringify(messageAction)) == 0)
                    {
                        logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName} but no one was found by that name");
                        database.Publish("channel:" + messageAction.Sender, Objectifier.Stringify(new MessageAction("ServerWarning", messageAction.Sender, "There was no recipient by that name")));
                    }
                    else
                    {
                        logger.Info($"{messageAction.Sender} sent message to {messageAction.ElementName}");
                    }                 
                }
                else if (curObject.ActionType == ActionType.SUBSCRIBE)
                {
                    SubscribeAction subscribeAction = (SubscribeAction)curObject;
                    if (subscribeAction.ElementType == ElementType.CHANNEL)
                    {
                        if (database.KeyExists("channel:" + subscribeAction.ElementName))
                        {
                            subscriber.Subscribe("channel:" + subscribeAction.ElementName);
                            // TODO return a success message to sender
                        }
                        else
                        {
                            //TODO return a non exist, perhaps you want to CREATE it message
                        }                        
                    }
                }
                else if (curObject.ActionType == ActionType.CREATE)
                {
                    CreateAction createAction = (CreateAction)curObject;
                    if (createAction.ElementType == ElementType.CHANNEL)
                    {
                        var name = "channel:" + createAction.ElementName;
                        if (!database.KeyExists(name))
                        {
                            database.StringSet(name, true); // todo figure out what to do with these channels
                            subscriber.Subscribe(name);
                            database.Publish(name, $"The {createAction.ElementName} channel has been created successfully!");
                        }
                        else
                        {
                            // TODO return with a "channel already exists with that name"
                        }
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

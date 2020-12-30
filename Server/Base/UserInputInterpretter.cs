using Server.Actions;
using Server.Elements;
using log4net;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text.RegularExpressions;

namespace Server.Base
{
    public class UserInputInterpretter
    {
        private readonly Dictionary<string, ActionType> actionMap;
        private static readonly ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);


        // This should probably use reflection and go through all the types of of actions and get the trigger words
        // TODO add logger to this
        public UserInputInterpretter()
        {
            actionMap = new Dictionary<string, ActionType>
            {
                { "tell", ActionType.MESSAGE },
                { "create", ActionType.CREATE },
                { "subscribe", ActionType.SUBSCRIBE },
                { "sub", ActionType.SUBSCRIBE },
                { "change", ActionType.CHANGE },
                { "edit", ActionType.CHANGE },
            };

            // tell <player/channel> <message>
            // create channel <channelname>
            // subscribe to <channelname>
            // change channel <channelname> name to <newChannelName>

            // TODO make the edit for toggling a channel to private/public
            // TODO make the command for listing out commands, this can loop through the above dictionary and print the keys
            // TODO for each command make a response for when just the command is sent to give a description
            // if someone sends "tell" respond with "you can tell someone something by saying 'tell <player> message' or you 
            // talk to a channel by saying 'tell <channel> message'
        }
        public ActionObject ParseActionFromText(string characterName, string input)
        {
            List<string> words = new List<string>(CleanInput(input).Split(" "));
            if (words.Count < 1)
            {
                logger.Info("WordCount is zero, returning null");
                return null;
            }

            ActionObject result;
            if (words.Count > 1)
            {
                logger.Info($"WordCount is {words.Count}, detected multi-word action");
                result = ProcessMultiWordAction(characterName, words);
            }
            else
            {
                logger.Info($"WordCount is {words.Count}, detected single word action");
                result = ProcessSingleWordAction(characterName, words);
            }
            return result;
        }
        private ActionObject ProcessMultiWordAction(string characterName, List<string> actionWords)
        {
            ActionObject multiWordActionResult = null;
            string command = actionWords[0];
            logger.Info($"Building action object based on command word: {command}");
            if (!actionMap.ContainsKey(command))
            {
                logger.Info($"Command not found in dictionary, returning null");
                return null;
            }
            ActionType actionType = actionMap[command];

            switch (actionType)
            {
                case ActionType.ATTACK:
                    break;
                case ActionType.CONSUME:
                    break;
                case ActionType.INSPECT:
                    break;
                case ActionType.LOGIN:
                    break;
                case ActionType.LOGOUT:
                    break;
                case ActionType.MESSAGE:
                    {
                        var recipient = actionWords[1];
                        var message = string.Join(' ', actionWords.GetRange(2, actionWords.Count-2));
                        multiWordActionResult = new MessageAction(characterName, recipient, message);
                    }
                    break;
                case ActionType.MOVEMENT:
                    break;
                case ActionType.PICKUP:
                    break;
                case ActionType.SUBSCRIBE:
                    {                        
                        var subscriptionTarget = actionWords[2];
                        multiWordActionResult = new SubscribeAction(characterName, ElementType.CHANNEL, subscriptionTarget);
                    }                       
                    break;
                case ActionType.CREATE:
                    {
                        var thingToCreate = actionWords[1];
                        if(thingToCreate.ToLower() == "channel" && actionWords.Count == 3)
                        {
                            multiWordActionResult = new CreateAction(characterName, ElementType.CHANNEL, actionWords[2]);
                        }
                        else
                        {
                            Console.WriteLine("Create failed, incorrect word count for channel creation");
                        }
                    }
                    break;
                case ActionType.CHANGE:
                    {
                        var editTarget = actionWords[1];
                        if(editTarget == "channel")
                        {
                            try
                            {
                                // edit channel <channelName> <name> <newName>
                                var channelName = actionWords[2];
                                var channelProperty = actionWords[3];
                                var newPropertyValue = actionWords[4];
                                if (newPropertyValue.ToLower() == "to")
                                {
                                    newPropertyValue = actionWords[5];
                                }
                                multiWordActionResult = new ChangeAction(characterName, ElementType.CHANNEL, channelName, channelProperty, newPropertyValue);
                                Console.WriteLine("Created edit action");
                            }catch(Exception e)
                            {
                                Console.WriteLine(e.ToString());
                            }
                        }
                    }
                    break;
                default:                    
                    break;
            }
            if(multiWordActionResult == null)
            {
                logger.Info($"Interpretter failed to derive action object from user input, returning null");
            }
            else
            {
                logger.Info($"Interpretter derived a {multiWordActionResult.ActionType} from user intpu");
            }
            return multiWordActionResult;
        }
        private string CleanInput(string val)
        {
            logger.Info("Cleaning the input from user");
            string cleanedInput = val;
            cleanedInput = cleanedInput.Trim();
            Regex.Replace(cleanedInput, @"\s+", " ");
            return cleanedInput;
        }
        private ActionObject ProcessSingleWordAction(string characterName, List<string> actionWords)
        {
            ActionObject singleWordActionResult = null;
            return singleWordActionResult;
        }
    }
}

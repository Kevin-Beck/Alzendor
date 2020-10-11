using Alzendor.Server.Core.Actions;
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Alzendor.Server.Core.DataTransfer
{
    public class UserInputInterpretter
    {
        private Dictionary<string, ActionType> actionMap;

        // This should probably use reflection and go through all the types of of actions and get the trigger words

        public UserInputInterpretter()
        {
            actionMap = new Dictionary<string, ActionType>();
            actionMap.Add("tell", ActionType.MESSAGE);
            actionMap.Add("create", ActionType.CREATE);
            actionMap.Add("listen", ActionType.SUBSCRIBE);
            
        }
        public ActionObject ParseActionFromText(string characterName, string input)
        {
            List<string> words = new List<string>(CleanInput(input).Split(" "));
            
            ActionObject result = null;

            if (words.Count < 1)
            {
                return null;
            }
            // Check for multi-word
            if(words.Count > 1)
            { 
                result = ProcessMultiWordAction(characterName, words);
            }
            else
            {
                result = ProcessSingleWordAction(characterName, words);
            }
            return result;
        }
        private ActionObject ProcessMultiWordAction(string characterName, List<string> actionWords)
        {
            ActionObject multiWordActionResult = null;
            string command = actionWords[0];
            if (!actionMap.ContainsKey(command))
            {
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
                        if (command == "tell")
                        {
                            var recipient = actionWords[1];
                            var message = string.Join(' ', actionWords.GetRange(2, actionWords.Count-2));

                            multiWordActionResult = new MessageAction(characterName, recipient, MessageType.CHANNEL, message);
                        }
                    }
                    break;
                case ActionType.MOVEMENT:
                    break;
                case ActionType.PICKUP:
                    break;
                case ActionType.SUBSCRIBE:
                    {                        
                        if (command == "listen")
                        {
                            var subscriptionTarget = actionWords[2];
                            multiWordActionResult = new SubscribeAction(characterName, subscriptionTarget, SubscriptionType.CHANNEL);
                        }
                    }                       
                    break;
                case ActionType.CREATE:
                    {
                        if(command == "create")
                        {
                            var thingToCreate = actionWords[1];
                            if(thingToCreate.ToLower() == "channel" && actionWords.Count == 3)
                            {
                                multiWordActionResult = new CreateAction(characterName, actionWords[1], actionWords[2]);
                            }
                            else
                            {
                                Console.WriteLine("Create failed, incorrect word count for channel creation");
                            }
                            // other create commands
                        }
                    }
                    break;
                default:
                    break;
            }

            return multiWordActionResult;
        }
        private string CleanInput(string val)
        {
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

using AlzendorCore.Utilities.Actions;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace AlzendorCore.Utilities.DataTransfer
{
    public class InputManager
    {
        private Dictionary<string, ActionType> actionMap;

        // This should probably use reflection and go through all the types of of actions and get the trigger words

        public InputManager()
        {
            actionMap = new Dictionary<string, ActionType>();
            actionMap.Add("say", ActionType.MESSAGE);
            actionMap.Add("tell", ActionType.MESSAGE);
        }
        public Action ParseActionFromText(string characterName, string input)
        {
            input = input.ToLower().Trim();
            Action result = null;
            // Check for whitespace first character
            if (input.Length < 1)
            {
                return null;
            }
            // Check for multi-word
            Regex multiWordRegex = new Regex(@"^\S+\s+\S+", RegexOptions.Compiled | RegexOptions.IgnoreCase);
            Match multiword = multiWordRegex.Match(input);
            if (multiword.Success)
            {
                result = ProcessMultiWordAction(characterName, input);
            }
            else
            {
                result = ProcessSingleWordAction(characterName, input);
            }
            return result;
        }
        private Action ProcessMultiWordAction(string characterName, string input)
        {
            Action multiWordActionResult = null;
            string command = input.Substring(0, input.IndexOf(" "));
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
                        if (command == "say")
                        {
                            var textMatch = Regex.Match(input, @"^say\s+(.*)");
                            var text = textMatch.Groups[1].Value;
                            multiWordActionResult = new MessageAction(characterName, "", MessageType.Local, text);
                        }
                        else if (command == "tell")
                        {
                            var textMatch = Regex.Match(input, @"^tell\s+(\S+)\s+(.*)");
                            var recipient = textMatch.Groups[1].Value;
                            var text = textMatch.Groups[2].Value;
                            multiWordActionResult = new MessageAction(characterName, recipient, MessageType.Direct, text);
                        }
                    }
                    break;
                case ActionType.MOVEMENT:
                    break;
                case ActionType.PICKUP:
                    break;
                default:
                    break;
            }

            return multiWordActionResult;
        }
        private Action ProcessSingleWordAction(string characterName, string input)
        {
            Action singleWordActionResult = null;
            return singleWordActionResult;
        }
    }
}
